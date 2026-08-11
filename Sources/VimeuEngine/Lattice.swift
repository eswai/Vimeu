import Foundation
import VimeuDict

/// One element of the conversion lattice: a dictionary token that covers
/// `begin..<end` of the reading.
///
/// `wcost`, `lid` and `rid` are Mozc's, and `wcost` already has the boundary
/// penalties folded in — see `Lattice.build`.
public struct LatticeNode: Sendable {
    public let begin: Int
    public let end: Int
    public let surface: String
    /// Word cost. **Smaller is more likely**, the same direction as Mozc.
    public let wcost: Int32
    public let lid: Int
    public let rid: Int
}

/// The conversion lattice, held as one flat node array with an index by start
/// position and another by end position.
///
/// Mozc's decoder needs both directions: the forward Viterbi walks the nodes
/// *ending* at a position to extend the nodes *beginning* there, and the
/// backward A\* walks the same edges the other way. Building both indices costs
/// one pass and saves every later step from scanning.
public struct Lattice: Sendable {
    public let nodes: [LatticeNode]
    /// Indices into `nodes`, by start position (`0..<length`).
    public let beginIndices: [[Int]]
    /// Indices into `nodes`, by end position (`0...length`).
    public let endIndices: [[Int]]
    /// Length of the reading in Unicode scalars.
    public let length: Int

    /// Word cost of the one-kana passthrough node placed at every position.
    ///
    /// Mozc's `AddCharacterTypeBasedNodes` gives its one-character node
    /// `kMaxCost = 32767`, deliberately enormous: the node exists so the lattice
    /// always spans the input, not because anyone should want to select it.
    /// Carried over unchanged.
    public static let unknownCost: Int32 = 32767

    /// Build the lattice for a hiragana reading.
    ///
    /// Positions are counted in **Unicode scalars**, not grapheme clusters, so
    /// that they line up with `codes` (which `DicReader.encode` produces one per
    /// scalar). Using `Character` here would silently desynchronise the two on
    /// any decomposed kana.
    ///
    /// Every position also gets a one-kana passthrough node, whether or not the
    /// dictionary had a hit there — Mozc calls `AddCharacterTypeBasedNodes`
    /// unconditionally, and matching that is what guarantees the lattice spans
    /// the whole input, so conversion can never fail outright. At cost 32767
    /// these nodes lose to anything real.
    ///
    /// The boundary penalties from `boundary.def` are added here rather than in
    /// the decoder, mirroring Mozc's `ApplyPrefixSuffixPenalty`: they depend on
    /// a node's position in the sentence, not on the transition, and folding
    /// them into `wcost` keeps the Viterbi inner loop to one addition.
    public static func build(
        reading: [Unicode.Scalar],
        codes: [UInt8],
        dictionary: DictionarySource
    ) -> Lattice {
        let n = reading.count
        var nodes: [LatticeNode] = []
        var beginIndices = [[Int]](repeating: [], count: max(n, 1))
        var endIndices = [[Int]](repeating: [], count: n + 1)

        for start in 0..<n {
            let before = nodes.count
            dictionary.forEachToken(codes: codes, from: start) { length, surface, cost, lid, rid in
                var wcost = cost
                if start == 0 { wcost += dictionary.prefixPenalty(lid) }
                if start + length == n { wcost += dictionary.suffixPenalty(rid) }
                nodes.append(LatticeNode(
                    begin: start, end: start + length,
                    surface: surface, wcost: wcost, lid: lid, rid: rid
                ))
            }
            let unknown = dictionary.unknownPOSID
            var unknownWCost = unknownCost
            if start == 0 { unknownWCost += dictionary.prefixPenalty(unknown) }
            if start + 1 == n { unknownWCost += dictionary.suffixPenalty(unknown) }
            nodes.append(LatticeNode(
                begin: start, end: start + 1,
                surface: String(reading[start]),
                wcost: unknownWCost, lid: unknown, rid: unknown
            ))

            for i in before..<nodes.count {
                beginIndices[start].append(i)
                endIndices[nodes[i].end].append(i)
            }
        }

        return Lattice(
            nodes: nodes, beginIndices: beginIndices, endIndices: endIndices, length: n
        )
    }
}
