import Foundation

/// Exact k-best whole-sentence paths, by backward A\* over the lattice.
///
/// The forward Viterbi has already computed, for every node, the cheapest cost
/// from BOS through that node. That number is an *exact* completion cost for any
/// suffix hanging off the node, which makes it a perfect A\* heuristic: expanding
/// the queue in order of
///
///     f = viterbi.cost[node] + g(suffix already built to the right)
///
/// pops whole paths in strictly increasing total cost, so the first `limit`
/// distinct ones are the true k-best. This is the shape of Mozc's
/// `NBestGenerator` (`fx = lnode->cost + gx` in `nbest_generator.cc`) with its
/// segment machinery — `structure_cost`, the candidate filter, the boundary
/// checks — left out, since vimeu has no bunsetsu to expose.
public enum NBest {
    /// One completed path: node indices left to right, and its total cost.
    public struct Path: Sendable {
        public let nodes: [Int]
        public let cost: Int32
    }

    /// A partial suffix: `node` is its leftmost node, `parent` links to the rest
    /// of the suffix (to the right), already built.
    private struct Element {
        let node: Int
        let parent: Int  // index into `elements`, -1 when this is the last node
        let g: Int32     // cost of the suffix from `node`'s start to EOS
        let f: Int32     // g + viterbi.cost[node] − node.wcost … see `expand`
    }

    /// How much further than `limit` the search may run, and how dear a path may
    /// be to still be worth having.
    ///
    /// Re-ranking (`Collocation`) needs to see past the candidates the window
    /// shows, but only as far as its own cost window reaches: a path dearer than
    /// that cannot be promoted whatever the pairs say, so producing it is pure
    /// waste. Bounding by cost rather than by count is what keeps the deeper
    /// search from being paid for on every sentence — most readings run out of
    /// paths inside the window long before `limit` is reached.
    public struct Extension: Sendable {
        /// Total cap on paths, `limit` included.
        public var limit: Int
        /// Paths past `limit` are kept only while they cost no more than this.
        public var ceiling: Int32

        public init(limit: Int, ceiling: Int32) {
            self.limit = limit
            self.ceiling = ceiling
        }
    }

    /// - Parameter limit: how many *distinct surface strings* to return — always
    ///   produced, whatever `extension` says.
    /// - Parameter extension: permission to go further, bounded by cost. Nil is
    ///   the plain k-best.
    /// - Parameter maxExpansions: safety valve. A long reading with a dense
    ///   lattice can have astronomically many paths, and the queue would happily
    ///   grow to fill memory chasing ties. Mozc caps its own search the same way
    ///   (`kMaxNodesSize`).
    public static func search(
        lattice: Lattice,
        viterbi: Viterbi,
        dictionary: DictionarySource,
        limit: Int,
        extension extra: Extension? = nil,
        maxExpansions: Int = 20_000
    ) -> [Path] {
        guard lattice.length > 0, viterbi.bestFinalNode != nil else { return [] }

        var elements: [Element] = []
        var queue = PriorityQueue()

        // Seed: every node that ends the sentence, with its EOS transition.
        for index in lattice.endIndices[lattice.length]
        where viterbi.cost[index] < Viterbi.unreachable {
            let node = lattice.nodes[index]
            let g = node.wcost + dictionary.transitionCost(node.rid, 0)
            push(&queue, &elements, Element(
                node: index, parent: -1, g: g,
                f: viterbi.cost[index] - node.wcost + g
            ))
        }

        var paths: [Path] = []
        var seen = Set<String>()
        var expansions = 0

        let hardLimit = max(limit, extra?.limit ?? 0)

        while expansions < maxExpansions, let elementIndex = queue.pop() {
            expansions += 1
            let element = elements[elementIndex]
            let node = lattice.nodes[element.node]

            // Elements come off in increasing `f`, and `f` is the exact total of
            // the cheapest whole path through this element — so once one is past
            // the ceiling, every path still to come is too.
            if let extra, paths.count >= limit, element.f > extra.ceiling { break }

            if node.begin == 0 {
                // Reached BOS: the suffix is a whole sentence, and `f` is already
                // its exact total — for a node at position 0 the Viterbi prefix
                // is nothing but the BOS transition.
                let nodes = unwind(elements, from: elementIndex)
                var text = ""
                for i in nodes { text += lattice.nodes[i].surface }
                if seen.insert(text).inserted {
                    paths.append(Path(nodes: nodes, cost: element.f))
                    if paths.count >= hardLimit { break }
                }
                continue
            }

            for leftIndex in lattice.endIndices[node.begin]
            where viterbi.cost[leftIndex] < Viterbi.unreachable {
                let left = lattice.nodes[leftIndex]
                let g = element.g + dictionary.transitionCost(left.rid, node.lid) + left.wcost
                push(&queue, &elements, Element(
                    node: leftIndex, parent: elementIndex, g: g,
                    f: viterbi.cost[leftIndex] - left.wcost + g
                ))
            }
        }

        return paths
    }

    private static func push(
        _ queue: inout PriorityQueue, _ elements: inout [Element], _ element: Element
    ) {
        elements.append(element)
        queue.push(index: elements.count - 1, priority: element.f)
    }

    /// Walk the parent chain, which runs left to right by construction.
    private static func unwind(_ elements: [Element], from start: Int) -> [Int] {
        var out: [Int] = []
        var cursor = start
        while cursor >= 0 {
            out.append(elements[cursor].node)
            cursor = elements[cursor].parent
        }
        return out
    }
}

/// A binary min-heap over `(priority, index)`.
///
/// Foundation has no priority queue and the search pushes on the order of tens
/// of thousands of elements per conversion, so a sorted array would be
/// quadratic. Ties break on insertion index to keep the output deterministic —
/// integer costs make ties routine.
private struct PriorityQueue {
    private var storage: [(priority: Int32, index: Int)] = []

    mutating func push(index: Int, priority: Int32) {
        storage.append((priority, index))
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard less(storage[child], storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard !storage.isEmpty else { return nil }
        let top = storage[0]
        storage[0] = storage[storage.count - 1]
        storage.removeLast()

        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count, less(storage[left], storage[smallest]) { smallest = left }
            if right < storage.count, less(storage[right], storage[smallest]) { smallest = right }
            if smallest == parent { break }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
        return top.index
    }

    private func less(
        _ a: (priority: Int32, index: Int), _ b: (priority: Int32, index: Int)
    ) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.index < b.index
    }
}
