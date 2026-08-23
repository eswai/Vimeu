import Foundation
import VimeuDict
import VimeuUserDict

/// One word of a candidate: the surface, the reading it was chosen for, and the
/// Mozc fields behind it.
///
/// The reading is what the tuning UI needs to name a dictionary entry — a
/// surface alone is not a key. The POS ids are what the 接続 pane needs to
/// explain why the candidate won.
public struct Segment: Sendable, Equatable {
    public let reading: String
    public let surface: String
    /// The node's word cost, boundary penalties included.
    public let wcost: Int32
    public let lid: Int
    public let rid: Int

    public init(reading: String, surface: String, wcost: Int32, lid: Int, rid: Int) {
        self.reading = reading
        self.surface = surface
        self.wcost = wcost
        self.lid = lid
        self.rid = rid
    }
}

/// One transition inside a candidate, including the two against BOS and EOS.
///
/// This is the whole content of the 接続 pane: it is where the answer to "why
/// did it choose that?" lives, and it is the part the predecessor could not
/// show because it had no connection costs at all.
public struct Boundary: Sendable, Equatable, Identifiable {
    /// Position in the candidate, 0 being the BOS transition. Also the `id`:
    /// two boundaries of one candidate can be identical in every other field
    /// (`… の … の …`), so nothing else here identifies a row.
    public let index: Int
    /// nil at the sentence start (BOS).
    public let left: Segment?
    /// nil at the sentence end (EOS).
    public let right: Segment?
    /// POS ids actually used for the lookup: `left.rid` and `right.lid`, with 0
    /// standing in for BOS/EOS.
    public let rid: Int
    public let lid: Int
    public let cost: Int32

    public var id: Int { index }
}

/// One whole-sentence conversion candidate.
public struct Candidate: Sendable, Equatable {
    public let text: String

    /// Total path cost, **lower is better** — Mozc's number, unscaled.
    ///
    /// `cost == wordCost + connectionCost + collocationCost` exactly, so the
    /// parts always reconcile with the total shown beside them.
    public let cost: Int32

    /// Σ of the words' costs (boundary penalties included).
    public let wordCost: Int32

    /// Σ of the connection costs along the path, BOS and EOS transitions
    /// included. This is the term the predecessor did not have.
    public let connectionCost: Int32

    /// Credit for the user's registered word pairs — **negative or zero**, and
    /// zero for everyone until the user registers a pair.
    ///
    /// The only term here that is not Mozc's. Kept as its own number rather than
    /// folded into the word costs so the tuning window can say plainly that this
    /// candidate won because of a pair, and which one. See `Collocation`.
    public let collocationCost: Int32

    /// The registered pairs this candidate satisfied, in order.
    public let collocations: [CollocationKey]

    /// The words it is made of, in order — how the candidate was segmented, and
    /// the handle the tuning UI uses to reach the entries behind it.
    public let segments: [Segment]

    /// The transitions between them, in order, BOS first and EOS last.
    public let boundaries: [Boundary]

    public var words: [String] { segments.map(\.surface) }

    public init(
        text: String,
        cost: Int32,
        wordCost: Int32,
        connectionCost: Int32,
        collocationCost: Int32 = 0,
        collocations: [CollocationKey] = [],
        segments: [Segment],
        boundaries: [Boundary]
    ) {
        self.text = text
        self.cost = cost
        self.wordCost = wordCost
        self.connectionCost = connectionCost
        self.collocationCost = collocationCost
        self.collocations = collocations
        self.segments = segments
        self.boundaries = boundaries
    }

    /// The same candidate with a collocation credit applied. The word and
    /// connection terms are untouched — only the total moves, and it moves by
    /// exactly the amount the new term reports.
    func creditingCollocations(_ matched: [CollocationKey], bonus: Int32) -> Candidate {
        Candidate(
            text: text,
            cost: wordCost + connectionCost + bonus,
            wordCost: wordCost,
            connectionCost: connectionCost,
            collocationCost: bonus,
            collocations: matched,
            segments: segments,
            boundaries: boundaries
        )
    }
}

/// The conversion engine: hiragana reading in, whole-sentence candidates out.
///
/// Deliberately free of any OS dependency — the macOS layer holds the IME state
/// (input mode, surrounding text, which app is focused) and this only ever sees
/// a finished kana reading. That is what keeps it unit-testable, which matters
/// because the IME process itself cannot be debugged with breakpoints.
///
/// There are no tuning coefficients. Mozc's cost model has no free parameters:
/// the total is the sum of word costs and connection costs, both straight from
/// the dictionary.
public final class Converter: Sendable {
    private let dictionary: DictionarySource

    public init(dictionary: DictionarySource) {
        self.dictionary = dictionary
    }

    public var statistics: DictionaryStatistics { dictionary.statistics }

    /// Hard cap on how deep the n-best goes when there are pairs to apply.
    ///
    /// Re-ranking can only reach what the search returned, and the candidate a
    /// pair is meant to rescue sits below the nine the window shows — `皮を剥く`
    /// is tenth for `かわをむく`. This is only a cap: the search actually stops at
    /// `UserDict.collocationWindow`, the cost beyond which re-ranking is not
    /// allowed to act anyway, and most readings run out of paths inside that
    /// window well before thirty-two.
    public static let rerankDepth = 32

    /// Convert a hiragana reading into candidates, best (cheapest) first.
    ///
    /// Distinct segmentations often produce the same string; those are collapsed
    /// so the candidate window never shows the same text twice. The ranking of
    /// what survives is unchanged.
    public func convert(reading: String, limit: Int = 9) -> [Candidate] {
        let scalars = Array(reading.unicodeScalars)
        guard !scalars.isEmpty else { return [] }

        let pairs = dictionary.collocations
        let negativePairs = dictionary.negativeCollocations

        let codes = dictionary.encode(reading)
        let lattice = Lattice.build(reading: scalars, codes: codes, dictionary: dictionary)
        let viterbi = Viterbi.run(lattice: lattice, dictionary: dictionary)
        let searchExtension: NBest.Extension?
        if !negativePairs.isEmpty {
            // A forbidden path may be the Viterbi winner, so its cost cannot be
            // used as the ceiling for the search. Keep enumerating until enough
            // allowed paths have been found; the normal NBest expansion cap is
            // still the safety valve for a dense lattice.
            let nodes = lattice.nodes
            let acceptsPath: @Sendable ([Int]) -> Bool = { path in
                !Collocation.containsNegativePair(
                    in: path.map { nodes[$0].surface }, table: negativePairs
                )
            }
            searchExtension = NBest.Extension(
                limit: max(limit, pairs.isEmpty ? 1 : Self.rerankDepth),
                ceiling: Int32.max,
                acceptsPath: acceptsPath
            )
        } else if !pairs.isEmpty {
            searchExtension = NBest.Extension(
                limit: max(limit, Self.rerankDepth),
                ceiling: viterbi.totalCost + UserDict.collocationWindow
            )
        } else {
            searchExtension = nil
        }

        let paths = NBest.search(
            lattice: lattice, viterbi: viterbi, dictionary: dictionary, limit: limit,
            extension: searchExtension
        )

        let candidates = paths.map { path in
            candidate(from: path, lattice: lattice, reading: scalars)
        }
        guard !pairs.isEmpty || !negativePairs.isEmpty else { return candidates }
        return Array(
            Collocation.rerank(
                candidates, pairs: pairs, negativePairs: negativePairs,
                dictionary: dictionary
            ).prefix(limit)
        )
    }

    /// Best conversion, or the reading unchanged when there is none.
    public func best(reading: String) -> String {
        convert(reading: reading, limit: 1).first?.text ?? reading
    }

    /// Turn a path into a candidate, recovering each node's reading from its
    /// span. Storing the reading on every lattice node instead would cost a
    /// string per node, of which a sentence generates thousands.
    private func candidate(from path: NBest.Path, lattice: Lattice, reading: [Unicode.Scalar]) -> Candidate {
        var segments: [Segment] = []
        segments.reserveCapacity(path.nodes.count)
        var text = ""
        var wordCost: Int32 = 0

        for index in path.nodes {
            let node = lattice.nodes[index]
            let end = min(node.end, reading.count)
            segments.append(Segment(
                reading: String(String.UnicodeScalarView(reading[node.begin..<end])),
                surface: node.surface,
                wcost: node.wcost,
                lid: node.lid,
                rid: node.rid
            ))
            text += node.surface
            wordCost += node.wcost
        }

        var boundaries: [Boundary] = []
        boundaries.reserveCapacity(segments.count + 1)
        var connectionCost: Int32 = 0
        var previous: Segment?
        for segment in segments {
            let rid = previous?.rid ?? 0  // 0 = BOS
            let cost = dictionary.transitionCost(rid, segment.lid)
            boundaries.append(Boundary(
                index: boundaries.count,
                left: previous, right: segment, rid: rid, lid: segment.lid, cost: cost
            ))
            connectionCost += cost
            previous = segment
        }
        if let last = previous {
            let cost = dictionary.transitionCost(last.rid, 0)  // 0 = EOS
            boundaries.append(Boundary(
                index: boundaries.count,
                left: last, right: nil, rid: last.rid, lid: 0, cost: cost
            ))
            connectionCost += cost
        }

        return Candidate(
            text: text,
            cost: wordCost + connectionCost,
            wordCost: wordCost,
            connectionCost: connectionCost,
            segments: segments,
            boundaries: boundaries
        )
    }
}
