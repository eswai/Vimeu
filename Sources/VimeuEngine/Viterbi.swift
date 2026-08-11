import Foundation

/// The forward pass of Mozc's decoder, transcribed from
/// `converter/immutable_converter.cc` (`Viterbi` / `ViterbiInternal`):
///
/// ```
/// cost(BOS)  = 0
/// cost(node) = min over lnode ( cost(lnode) + trans(lnode.rid, node.lid) ) + node.wcost
/// cost(EOS)  = min over lnode ( cost(lnode) + trans(lnode.rid, 0) )
/// ```
///
/// BOS and EOS are both POS id 0, as they are in `id.def`. There is no beam and
/// no pruning: the lattice is small enough for exact dynamic programming, which
/// is what Mozc does too.
public struct Viterbi: Sendable {
    /// `cost[i]` — the cheapest total from BOS through the *end* of `nodes[i]`,
    /// including that node's own `wcost`.
    public let cost: [Int32]
    /// `previous[i]` — the node index the best path reached `nodes[i]` from,
    /// or -1 when that was BOS. `Int32.min` marks a node no path reaches.
    public let previous: [Int]
    /// The cheapest whole-sentence total, i.e. the cost at EOS.
    public let totalCost: Int32
    /// Index of the last node on the best path, or nil for an empty lattice.
    public let bestFinalNode: Int?

    /// Stands in for infinity. Mozc uses `INT_MAX >> 2` for the same reason: a
    /// new cost gets computed *from* this value, so it has to leave headroom.
    public static let unreachable: Int32 = Int32.max >> 2

    public static func run(lattice: Lattice, dictionary: DictionarySource) -> Viterbi {
        let nodes = lattice.nodes
        var cost = [Int32](repeating: unreachable, count: nodes.count)
        var previous = [Int](repeating: -1, count: nodes.count)

        // One row of the connection matrix at a time, as in Mozc's
        // `CachingConnector`: the inner loop holds `node.lid` fixed and varies
        // `left.rid`, so `trans(rid, lid)` for the current lid can be memoised
        // by rid. A generation stamp invalidates the row without rewriting it —
        // lid changes about once per node, and clearing a posCount-wide array
        // that often would cost more than the lookups it saves.
        var cachedLID = -1
        var cacheGeneration: Int32 = 0
        var cacheValue = [Int32](repeating: 0, count: dictionary.posCount)
        var cacheStamp = [Int32](repeating: 0, count: dictionary.posCount)

        for position in 0..<lattice.length {
            for index in lattice.beginIndices[position] {
                let node = nodes[index]

                if node.lid != cachedLID {
                    cachedLID = node.lid
                    cacheGeneration &+= 1
                }

                var best = unreachable
                var bestFrom = -1
                if position == 0 {
                    best = dictionary.transitionCost(0, node.lid)  // from BOS
                } else {
                    for leftIndex in lattice.endIndices[position] {
                        guard cost[leftIndex] < unreachable else { continue }
                        let rid = nodes[leftIndex].rid
                        let transition: Int32
                        if rid < cacheValue.count, cacheStamp[rid] == cacheGeneration {
                            transition = cacheValue[rid]
                        } else {
                            transition = dictionary.transitionCost(rid, node.lid)
                            if rid < cacheValue.count {
                                cacheValue[rid] = transition
                                cacheStamp[rid] = cacheGeneration
                            }
                        }
                        let candidate = cost[leftIndex] + transition
                        if candidate < best {
                            best = candidate
                            bestFrom = leftIndex
                        }
                    }
                    guard bestFrom >= 0 else { continue }
                }
                cost[index] = best + node.wcost
                previous[index] = bestFrom
            }
        }

        // EOS: POS id 0 again, and no word cost of its own.
        var totalCost = unreachable
        var bestFinal: Int?
        for index in lattice.endIndices[lattice.length] where cost[index] < unreachable {
            let candidate = cost[index] + dictionary.transitionCost(nodes[index].rid, 0)
            if candidate < totalCost {
                totalCost = candidate
                bestFinal = index
            }
        }

        return Viterbi(
            cost: cost, previous: previous, totalCost: totalCost, bestFinalNode: bestFinal
        )
    }

    /// The best path, left to right, as node indices.
    public func bestPath() -> [Int] {
        guard var index = bestFinalNode else { return [] }
        var reversed: [Int] = [index]
        while previous[index] >= 0 {
            index = previous[index]
            reversed.append(index)
        }
        return reversed.reversed()
    }
}
