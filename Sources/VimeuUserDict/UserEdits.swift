import Foundation

/// The user's edits to the dictionary — the only thing vimeu ever writes.
///
/// vimeu has no automatic learning: committing a conversion never touches the
/// dictionary. "Make this conversion win" is expressed by an explicit edit, and
/// this is what one looks like.
///
/// An edit records only what the user asked for, never the system value it
/// shadows. Provenance is decided by asking the *system* dictionary whether it
/// has the key (`OverlaidDictionary`), which is what lets `vimeu.dic` be rebuilt
/// and swapped underneath without invalidating anything here.
public enum UserDict {
    /// Costs are Mozc's own: **smaller is more likely**. The shipped dictionary's
    /// values run roughly 0–16000; the range here is the full width the on-disk
    /// `Int16` holds, so an edit can always push a word past any system word.
    public static let costRange: ClosedRange<Int32> = 0...32767

    /// One press of 強める / 弱める.
    ///
    /// Mozc's costs are log probabilities scaled by 500 (its own `kCostDiff` is
    /// `500·log(1000) = 3453`), so 500 is one *e*-fold. That is a step the user
    /// can feel without it swamping the connection costs, which are of the same
    /// magnitude — the whole point of this design is that the two terms are
    /// comparable.
    public static let costStep: Int32 = 500

    public static func clampCost(_ v: Int32) -> Int32 {
        min(max(v, costRange.lowerBound), costRange.upperBound)
    }

    /// UTF-8 byte order, i.e. code-point order — the same relation the packed
    /// dictionary uses. `String`'s own `<` is Unicode canonical ordering, which
    /// is a different relation and would disagree.
    public static func utf8Less(_ a: String, _ b: String) -> Bool {
        var ai = a.utf8.makeIterator()
        var bi = b.utf8.makeIterator()
        while true {
            switch (ai.next(), bi.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?):
                if x != y { return x < y }
            }
        }
    }

    /// What a registered collocation is worth, and how far down the list it is
    /// allowed to reach.
    ///
    /// Both are Mozc's `kCostDiff = 500·log(1000) = 3453`, the same number
    /// `CollocationRewriter` uses to bound its own promotions. Reading it as a
    /// window: a candidate more than a thousand times less likely than the best
    /// one is not in the running, and no collocation table should be able to put
    /// it there. Reading it as a bonus: a pair the user registered is worth
    /// exactly enough to win anywhere inside that window and nothing outside it.
    ///
    /// Making the two equal is what keeps this from being a free parameter.
    public static let collocationBonus: Int32 = 3453
    public static var collocationWindow: Int32 { collocationBonus }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// A pair of words the user wants to see chosen together — 皮 と 剥く.
///
/// This is the co-occurrence counterpart of `WordEdit`: the dictionary knows
/// what `かわ` and `むく` can mean, and the connection matrix knows that
/// 名詞 → 助詞 → 動詞 is a sentence, but neither has any way to prefer 皮を剥く
/// over 川を向く — every reading here shares the same POS sequence, so the
/// connection cost is identical for all of them. The only thing that separates
/// them is which words actually occur together, and that is what this records.
///
/// Deliberately not a corpus statistic. A hand-written pair can only fail to
/// fire; a mined one can also fire where it should not, and the user has no way
/// to see why. See DESIGN.md §3.5.
public struct CollocationEdit: Sendable, Equatable, Identifiable {
    public var left: String
    public var right: String
    public var updatedAt: Int64

    public var id: String { left + "\t" + right }

    public init(left: String, right: String, updatedAt: Int64 = UserDict.now()) {
        self.left = left
        self.right = right
        self.updatedAt = updatedAt
    }

    public var key: CollocationKey { CollocationKey(left: left, right: right) }
}

/// Ordered: `(皮, 剥く)` is not `(剥く, 皮)`. Word order carries the whole
/// meaning of a collocation, so folding the two would register pairs the user
/// never asked for.
public struct CollocationKey: Hashable, Sendable {
    public var left: String
    public var right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }
}

/// A user edit to one `(reading, surface)` entry.
///
/// `cost == nil` with `disabled == true` is the plain "hide this word" edit.
/// A cost with `disabled == false` is either an override of a system entry or a
/// user-added word — which of the two is not recorded here, because that depends
/// on the system dictionary in play.
///
/// The key deliberately stops at `(reading, surface)` even though the packed
/// dictionary keys tokens by `(reading, surface, lid, rid)`. Mozc registers one
/// spelling under several POS ids, and making the user choose between
/// `名詞,固有名詞,人名,姓` and `名詞,一般` before they can raise a word would be a
/// tuning UI nobody wants. An override therefore applies to *every* token of the
/// pair, and a delete hides all of them.
public struct WordEdit: Sendable, Equatable {
    public var reading: String
    public var surface: String
    public var cost: Int32?
    public var disabled: Bool
    public var updatedAt: Int64

    public init(
        reading: String, surface: String, cost: Int32?, disabled: Bool,
        updatedAt: Int64 = UserDict.now()
    ) {
        self.reading = reading
        self.surface = surface
        self.cost = cost.map(UserDict.clampCost)
        self.disabled = disabled
        self.updatedAt = updatedAt
    }

    public var key: WordKey { WordKey(reading: reading, surface: surface) }
}

public struct WordKey: Hashable, Sendable {
    public var reading: String
    public var surface: String

    public init(reading: String, surface: String) {
        self.reading = reading
        self.surface = surface
    }
}
