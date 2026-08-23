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

    /// What a *disabled* connection costs: the top of the range, which is also
    /// Mozc's `kMaxCost` and the cost of the pass-through kana node.
    ///
    /// Not infinity. A forbidden transition still has to be traversable, because
    /// the lattice must span the whole input even when every path through it is
    /// one the user asked not to see — the same reason Mozc gives its unknown
    /// nodes a finite cost rather than dropping them.
    public static var forbiddenConnectionCost: Int32 { costRange.upperBound }

    public static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

/// The direction of a user-defined word relationship.
///
/// Positive relations are ordered and give a matching candidate a bounded
/// credit. Negative relations mean that the two words must not occur together;
/// they are therefore matched in either order and are enforced as a hard
/// candidate filter by the engine.
public enum CollocationPolarity: String, CaseIterable, Sendable {
    case positive
    case negative

    public var title: String {
        switch self {
        case .positive: return "正の共起"
        case .negative: return "負の共起"
        }
    }
}

/// A user-defined relation between two words — 皮 と 剥く.
///
/// For a positive relation, this is the co-occurrence counterpart of `WordEdit`: the dictionary knows
/// what `かわ` and `むく` can mean, and the connection matrix knows that
/// 名詞 → 助詞 → 動詞 is a sentence, but neither has any way to prefer 皮を剥く
/// over 川を向く — every reading here shares the same POS sequence, so the
/// connection cost is identical for all of them. The only thing that separates
/// them is which words actually occur together, and that is what this records.
/// A negative relation instead records that the two surfaces must not occur in
/// one candidate; it is unordered and enforced as a hard filter.
///
/// Deliberately not a corpus statistic. A hand-written pair can only fail to
/// fire; a mined one can also fire where it should not, and the user has no way
/// to see why. See DESIGN.md §3.5.
public struct CollocationEdit: Sendable, Equatable, Identifiable {
    public var left: String
    public var right: String
    public var polarity: CollocationPolarity
    public var updatedAt: Int64

    public var id: String { left + "\t" + right }

    public init(
        left: String, right: String,
        polarity: CollocationPolarity = .positive,
        updatedAt: Int64 = UserDict.now()
    ) {
        self.left = left
        self.right = right
        self.polarity = polarity
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

    /// A stable, unordered spelling for a negative relation.
    ///
    /// Positive relations keep their direction. Negative relations describe
    /// mutual exclusion, so `A`/`B` and `B`/`A` are the same relationship.
    public static func unordered(_ left: String, _ right: String) -> CollocationKey {
        UserDict.utf8Less(left, right)
            ? CollocationKey(left: left, right: right)
            : CollocationKey(left: right, right: left)
    }

    public func isUnorderedMatch(_ other: CollocationKey) -> Bool {
        self == other || (left == other.right && right == other.left)
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

/// A user edit to one cell of Mozc's connection matrix — 左の品詞 → 右の品詞.
///
/// The third kind of edit, and the sharpest. A `WordEdit` moves one entry, so it
/// only ever changes sentences that entry appears in. This moves a *POS pair*,
/// so it changes every sentence in the language that crosses that boundary. That
/// is not a defect to be fixed — a transition is a property of the grammar, not
/// of a word — but it is why the tuning window states the scope on the pane and
/// why DESIGN.md §4.2 asks for the effect to be measured (`vimeu-eval --user`)
/// rather than judged from one sentence.
///
/// `cost == nil` with `disabled == true` is "この接続を使わない"; the effective
/// value becomes `UserDict.forbiddenConnectionCost`, and the row stays so it can
/// be undone. A cost with `disabled == false` is a plain override. Both are
/// absolute: 強める / 弱める resolve against the value in force at the time of
/// the press, exactly as `WordEdit` does, so rebuilding `vimeu.dic` cannot move
/// an edit the user tuned by eye.
public struct ConnectionEdit: Sendable, Equatable {
    /// `id.def` feature string of the left word's **rid** — `BOS/EOS,*,*,*,*,*,*`
    /// at the start of a sentence.
    public var left: String
    /// `id.def` feature string of the right word's **lid**, `BOS/EOS,…` at the end.
    public var right: String
    public var cost: Int32?
    public var disabled: Bool
    public var updatedAt: Int64

    public init(
        left: String, right: String, cost: Int32?, disabled: Bool,
        updatedAt: Int64 = UserDict.now()
    ) {
        self.left = left
        self.right = right
        self.cost = cost.map(UserDict.clampCost)
        self.disabled = disabled
        self.updatedAt = updatedAt
    }

    public var key: ConnectionKey { ConnectionKey(left: left, right: right) }

    /// The value conversion should use, or nil when the row says nothing.
    public var effectiveCost: Int32? {
        if disabled { return UserDict.forbiddenConnectionCost }
        return cost
    }
}

/// Ordered, and keyed by POS **feature string** rather than by the numeric id
/// the matrix is indexed with.
///
/// The ids are `id.def` line numbers. They are stable within one Mozc data drop
/// and not across two: a POS inserted upstream renumbers everything after it,
/// and an edit stored as `1583 → 261` would then silently apply to a different
/// pair of parts of speech — the one failure mode a user could never diagnose.
/// The names are the same thing the 接続 pane shows, so what is in the file is
/// what was on screen. Resolving them back to ids is `OverlaidDictionary`'s job
/// and happens against whichever dictionary is loaded; a name that no longer
/// exists drops out of the effective table and stays in the file, exactly as a
/// word edit for a reading the dictionary no longer has does.
public struct ConnectionKey: Hashable, Sendable {
    public var left: String
    public var right: String

    public init(left: String, right: String) {
        self.left = left
        self.right = right
    }
}
