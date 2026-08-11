import Foundation
import VimeuUserDict

/// Word-to-word co-occurrence, layered on top of the Mozc cost model.
///
/// Mozc's two terms are blind to this by construction. The word cost knows how
/// common `皮` is on its own, the connection cost knows that 名詞 → 助詞 → 動詞
/// is a sentence — and for `かわをむく` every reading has the identical POS
/// sequence, so the connection term is the same number for all of them and the
/// ranking falls to a 15-point difference between `川` and `皮`. Nothing in the
/// dictionary says that it is *皮* that gets 剥かれる.
///
/// So this is a third term, and it is kept deliberately small:
///
/// - It is a **boolean**, not a score. A pair is registered or it is not; there
///   is no weight to tune, no threshold, and no coefficient — which is what lets
///   §1.1's "no free parameters" survive the addition.
/// - It is applied by **re-ranking the n-best**, not inside the Viterbi. The
///   words of a collocation are not adjacent (`皮 を 剥く`), so scoring them in
///   the lattice would mean carrying the previous content word in the search
///   state, which breaks both the Markov property the decoder rests on and the
///   admissibility of the A\* heuristic in §3.3. Re-ranking a finished list
///   leaves the decoder exactly as it was.
/// - It is **bounded** by `UserDict.collocationWindow`, the same window Mozc's
///   own `CollocationRewriter` uses. It reorders candidates that were already
///   close; it cannot resurrect one the language model ruled out.
public enum Collocation {
    /// Which words of a path can take part in a pair.
    ///
    /// Content words (自立語) only. `皮 を 剥く` is three nodes, and the pair the
    /// user means is 皮 × 剥く with the particle passed over — so the particle,
    /// and everything else that cannot stand on its own, is skipped rather than
    /// being made part of a key. Mozc reaches the same pair by working in
    /// 文節 units, which vimeu does not have (§3.6); skipping 付属語 is the same
    /// grouping expressed on a flat node list.
    ///
    /// Judged from the `id.def` feature string, so it follows whatever POS the
    /// packed dictionary was built with rather than a hardcoded id table.
    public static func isContentWord(posName: String) -> Bool {
        var parts = posName.split(separator: ",", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        let major = parts[0]
        // Particles and auxiliaries attach to the word before them; symbols and
        // the sentence terminals are not words at all. 接頭詞 attaches to the
        // word *after* it, and so is equally not the head of anything.
        switch major {
        case "助詞", "助動詞", "記号", "接頭詞", "BOS/EOS", "フィラー", "その他":
            return false
        default:
            break
        }
        guard parts.count > 1 else { return true }
        // 非自立 and 接尾 say the same thing one level down: 動詞,非自立 (`いる`,
        // `くる`), 名詞,接尾 (`さん`, `的`) cannot head a collocation.
        switch parts[1] {
        case "非自立", "接尾", "動詞非自立的":
            return false
        default:
            return true
        }
    }

    /// The content words of a candidate, in order, as indices into `segments`.
    public static func contentWordIndices(
        of segments: [Segment], dictionary: DictionarySource
    ) -> [Int] {
        segments.indices.filter { isContentWord(posName: dictionary.posName(segments[$0].lid)) }
    }

    /// The pairs a candidate offers: each content word with the next one.
    ///
    /// Only *adjacent* content words. Two words with another content word
    /// between them are not a collocation in any sense a user could predict, and
    /// allowing the gap would make one registered pair fire across half a
    /// sentence.
    public static func pairs(
        of segments: [Segment], dictionary: DictionarySource
    ) -> [CollocationKey] {
        let content = contentWordIndices(of: segments, dictionary: dictionary)
        guard content.count > 1 else { return [] }
        return zip(content, content.dropFirst()).map {
            CollocationKey(left: segments[$0].surface, right: segments[$1].surface)
        }
    }

    /// Re-rank candidates by the registered pairs, cheapest first.
    ///
    /// Every candidate within `collocationWindow` of the best one is credited
    /// `collocationBonus` per pair it satisfies. Candidates outside the window
    /// are left alone, so a wrong entry in the table can only shuffle the top of
    /// the list — it cannot promote something the cost model put far below.
    ///
    /// Multiple hits add up, which is the whole of the ordering rule between two
    /// candidates that both match: the one that satisfies more pairs wins, and
    /// if they tie there, their original costs decide. That is why no per-pair
    /// weight is needed.
    static func rerank(
        _ candidates: [Candidate], pairs table: Set<CollocationKey>,
        dictionary: DictionarySource
    ) -> [Candidate] {
        guard !table.isEmpty, let best = candidates.first?.cost else { return candidates }
        let ceiling = best + UserDict.collocationWindow

        let scored = candidates.map { candidate -> Candidate in
            guard candidate.cost <= ceiling else { return candidate }
            let matched = pairs(of: candidate.segments, dictionary: dictionary)
                .filter(table.contains)
            guard !matched.isEmpty else { return candidate }
            return candidate.creditingCollocations(
                matched, bonus: -UserDict.collocationBonus * Int32(matched.count)
            )
        }
        // Stable in the original order, which is already the exact cost order —
        // so candidates the table says nothing about keep the decoder's ranking
        // among themselves.
        return scored.enumerated()
            .sorted { $0.element.cost != $1.element.cost
                ? $0.element.cost < $1.element.cost
                : $0.offset < $1.offset }
            .map(\.element)
    }
}
