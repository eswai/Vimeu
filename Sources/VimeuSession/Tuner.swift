import Foundation
import VimeuEngine
import VimeuInput
import VimeuUserDict

/// State and actions behind the tuning window (README「変換の調整」), without
/// any UI framework: the Linux `vimeu-tune` app drives it through the C API
/// as JSON. It mirrors `VimeuUI/AdjustmentViewModel.swift`, which needs
/// Combine and therefore does not build on Linux.
///
/// Every action edits the user dictionary and re-converts immediately, so the
/// effect of a change is visible in the candidate list straight away. There is
/// no unsaved buffer: リセット and 復活 are themselves edits. The fcitx5 addon
/// picks the saved TSV files up through inotify (DESIGN.md §8.2).
public final class Tuner {
    public let engine: Engine

    public private(set) var reading = ""
    public private(set) var candidates: [Candidate] = []
    public private(set) var words: [WordKnob] = []
    public private(set) var selectedCandidate = 0
    public private(set) var collocationChoices: [String] = []
    public private(set) var message: String?

    public init(engine: Engine) {
        self.engine = engine
        reconvert()
    }

    // MARK: - Commands

    public enum Command: Equatable {
        case setReading(String)
        case selectCandidate(Int)
        case setWordCost(reading: String, surface: String, cost: Int32)
        case boostWord(reading: String, surface: String, steps: Int)
        case deleteWord(reading: String, surface: String)
        case reviveWord(reading: String, surface: String)
        case resetWord(reading: String, surface: String)
        case addWord(reading: String, surface: String, cost: Int32)
        case setConnectionCost(rid: Int, lid: Int, cost: Int32)
        case boostConnection(rid: Int, lid: Int, steps: Int)
        case disableConnection(rid: Int, lid: Int)
        case reviveConnection(rid: Int, lid: Int)
        case resetConnection(rid: Int, lid: Int)
        case addCollocation(left: String, right: String, negative: Bool)
        case removeCollocation(left: String, right: String)
        /// Re-read the TSV files (edited elsewhere) and convert again.
        case reload
    }

    public enum CommandError: Error, Equatable, CustomStringConvertible {
        case malformed(String)
        case unknownOperation(String)
        case missing(String)
        case invalid(String)

        public var description: String {
            switch self {
            case .malformed(let s): return "malformed command: \(s)"
            case .unknownOperation(let s): return "unknown op: \(s)"
            case .missing(let s): return "missing field: \(s)"
            case .invalid(let s): return "invalid: \(s)"
            }
        }
    }

    public func run(_ command: Command) throws {
        if case .setReading(let r) = command {
            reading = Self.normalizeReading(r)
            reconvert()
            return
        }
        if case .selectCandidate(let i) = command {
            guard candidates.indices.contains(i), i < Self.candidateRows else { throw CommandError.invalid("candidate \(i)") }
            selectedCandidate = i
            return
        }
        if case .reload = command {
            engine.reloadUserDictionary()
            reconvert()
            return
        }
        guard let editor = engine.editor else { throw CommandError.invalid("辞書が読み込まれていません") }
        switch command {
        case let .setWordCost(r, s, cost): editor.setWordCost(reading: r, surface: s, cost: cost)
        case let .boostWord(r, s, steps): editor.boostWord(reading: r, surface: s, steps: steps)
        case let .deleteWord(r, s): editor.deleteWord(reading: r, surface: s)
        case let .reviveWord(r, s): editor.reviveWord(reading: r, surface: s)
        case let .resetWord(r, s): editor.resetWord(reading: r, surface: s)
        case let .addWord(r, s, cost):
            let r = Self.normalizeReading(r)
            guard !r.isEmpty, !s.isEmpty else { throw CommandError.invalid("読みと表記が必要です") }
            editor.setWordCost(reading: r, surface: s, cost: cost)
        case let .setConnectionCost(rid, lid, cost): editor.setConnectionCost(rid: rid, lid: lid, cost: cost)
        case let .boostConnection(rid, lid, steps): editor.boostConnection(rid: rid, lid: lid, steps: steps)
        case let .disableConnection(rid, lid): editor.disableConnection(rid: rid, lid: lid)
        case let .reviveConnection(rid, lid): editor.reviveConnection(rid: rid, lid: lid)
        case let .resetConnection(rid, lid): editor.resetConnection(rid: rid, lid: lid)
        case let .addCollocation(left, right, negative):
            // A pair is two different words; the window disables the button
            // otherwise, and the core should not trust that.
            guard !left.isEmpty, !right.isEmpty, left != right else {
                throw CommandError.invalid("異なる 2 語が必要です")
            }
            editor.addCollocation(left: left, right: right, polarity: negative ? .negative : .positive)
        case let .removeCollocation(left, right): editor.removeCollocation(left: left, right: right)
        case .setReading, .selectCandidate, .reload: break
        }
        reconvert()
    }

    /// Parse and run one JSON command, e.g. `{"op":"boostWord","reading":"かわ","surface":"皮","steps":1}`.
    public func run(json: String) throws {
        try run(Self.parse(json))
    }

    static func parse(_ json: String) throws -> Command {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CommandError.malformed(json)
        }
        func str(_ k: String) throws -> String {
            guard let v = obj[k] as? String else { throw CommandError.missing(k) }
            return v
        }
        func int(_ k: String) throws -> Int {
            guard let v = obj[k] as? NSNumber else { throw CommandError.missing(k) }
            return v.intValue
        }
        func cost(_ k: String) throws -> Int32 { Int32(clamping: try int(k)) }
        guard let op = obj["op"] as? String else { throw CommandError.missing("op") }
        switch op {
        case "setReading": return .setReading(try str("reading"))
        case "selectCandidate": return .selectCandidate(try int("index"))
        case "setWordCost": return .setWordCost(reading: try str("reading"), surface: try str("surface"), cost: try cost("cost"))
        case "boostWord": return .boostWord(reading: try str("reading"), surface: try str("surface"), steps: try int("steps"))
        case "deleteWord": return .deleteWord(reading: try str("reading"), surface: try str("surface"))
        case "reviveWord": return .reviveWord(reading: try str("reading"), surface: try str("surface"))
        case "resetWord": return .resetWord(reading: try str("reading"), surface: try str("surface"))
        case "addWord": return .addWord(reading: try str("reading"), surface: try str("surface"), cost: try cost("cost"))
        case "setConnectionCost": return .setConnectionCost(rid: try int("rid"), lid: try int("lid"), cost: try cost("cost"))
        case "boostConnection": return .boostConnection(rid: try int("rid"), lid: try int("lid"), steps: try int("steps"))
        case "disableConnection": return .disableConnection(rid: try int("rid"), lid: try int("lid"))
        case "reviveConnection": return .reviveConnection(rid: try int("rid"), lid: try int("lid"))
        case "resetConnection": return .resetConnection(rid: try int("rid"), lid: try int("lid"))
        case "addCollocation":
            return .addCollocation(left: try str("left"), right: try str("right"),
                                   negative: (obj["polarity"] as? String) == "negative")
        case "removeCollocation": return .removeCollocation(left: try str("left"), right: try str("right"))
        case "reload": return .reload
        default: throw CommandError.unknownOperation(op)
        }
    }

    /// ASCII romaji becomes kana with the IME's own table, so the reading can
    /// be typed with the input method off (typing it through vimeu would
    /// convert it). Kana and anything else pass through unchanged.
    public static func normalizeReading(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.contains(where: { $0.isASCII && CharacterSet.letters.contains($0) }) else {
            return trimmed
        }
        var buffer = InputBuffer()
        for ch in trimmed {
            if ch.isASCII, InputBuffer.isComposingCharacter(ch) {
                buffer.accept(Character(ch.lowercased()))
            } else if let punct = Session.punctuation[ch] {
                buffer.acceptKana(punct)
            } else {
                buffer.acceptKana(String(ch))
            }
        }
        return buffer.flushForConversion()
    }

    // MARK: - Conversion

    private func reconvert() {
        guard let editor = engine.editor else {
            candidates = []
            words = []
            collocationChoices = []
            message = "辞書が読み込まれていません" + (engine.loadFailure.map { "（\($0)）" } ?? "")
            return
        }
        message = editor.lastError
        guard !reading.isEmpty else {
            candidates = []
            words = []
            collocationChoices = []
            selectedCandidate = 0
            return
        }
        // The 接続 pane explains one candidate; an edit is meant to move
        // candidates around, so follow the text, not the row.
        let wasSelected = candidates.indices.contains(selectedCandidate) ? candidates[selectedCandidate].text : nil
        // Every candidate: the word and collocation panes pool their entries,
        // and truncating would hide entries whose sentence ranked low.
        candidates = Converter(dictionary: editor.dictionary).convert(reading: reading, limit: NBest.maxExpansions)
        if let wasSelected, let moved = candidates.firstIndex(where: { $0.text == wasSelected }) {
            selectedCandidate = moved
        } else if !candidates.indices.contains(selectedCandidate) {
            selectedCandidate = 0
        }
        words = editor.wordKnobs(for: candidates, reading: reading)
        collocationChoices = editor.collocationChoices(for: candidates)
    }

    // MARK: - State

    public struct State: Codable, Equatable {
        public struct CandidateRow: Codable, Equatable {
            public let text: String
            public let cost: Int32
            public let wordCost: Int32
            public let connectionCost: Int32
            public let collocationCost: Int32
            /// "読み/表層" per word, for the row's breakdown.
            public let segments: [String]
        }

        public struct WordRow: Codable, Equatable {
            public let reading: String
            public let surface: String
            public let cost: Int32
            public let baseCost: Int32?
            public let pos: String
            public let userOverride: Bool
            public let deleted: Bool
            /// Used by the selected candidate.
            public let inSelected: Bool
            /// The same surface appears on another row, so show the reading.
            public let ambiguous: Bool
        }

        public struct ConnectionRow: Codable, Equatable {
            public let index: Int
            public let left: String
            public let right: String
            public let rid: Int
            public let lid: Int
            public let leftPOS: String
            public let rightPOS: String
            public let cost: Int32
            public let baseCost: Int32
            public let userOverride: Bool
            public let disabled: Bool
        }

        public struct CollocationRow: Codable, Equatable {
            public let left: String
            public let right: String
            public let negative: Bool
            /// A positive pair some current candidate satisfies.
            public let active: Bool
        }

        public let reading: String
        public let message: String?
        public let ready: Bool
        public let userDirectory: String
        /// The best `Tuner.candidateRows` candidates; `candidateCount` is all of them.
        public let candidates: [CandidateRow]
        public let candidateCount: Int
        public let selectedCandidate: Int
        public let words: [WordRow]
        public let connections: [ConnectionRow]
        public let connectionEditCount: Int
        public let collocations: [CollocationRow]
        public let collocationChoices: [String]
        public let costStep: Int32
        public let costMax: Int32
        public let collocationBonus: Int32
    }

    /// Rows of the candidate list sent to the window. The word and
    /// collocation panes still pool every candidate; only the list a person
    /// scrolls is cut, which keeps an edit's round trip small (one reading
    /// can have 6,500 candidates, a megabyte of JSON).
    public static let candidateRows = 300

    public var state: State {
        let editor = engine.editor
        var seen = Set<String>(), repeated = Set<String>()
        for w in words where !seen.insert(w.surface).inserted { repeated.insert(w.surface) }
        let selectedIDs: Set<String> = candidates.indices.contains(selectedCandidate)
            ? Set(candidates[selectedCandidate].segments.map { $0.reading + "\t" + $0.surface }) : []
        let connections: [ConnectionKnob] = editor.flatMap { e in
            candidates.indices.contains(selectedCandidate) ? e.connectionKnobs(for: candidates[selectedCandidate]) : nil
        } ?? []
        let collocations = editor?.collocations ?? []
        return State(
            reading: reading,
            message: message,
            ready: editor != nil,
            userDirectory: engine.userDirectory.path,
            candidates: candidates.prefix(Self.candidateRows).map { c in
                .init(text: c.text, cost: c.cost, wordCost: c.wordCost, connectionCost: c.connectionCost,
                      collocationCost: c.collocationCost,
                      segments: c.segments.map { "\($0.reading)/\($0.surface)" })
            },
            candidateCount: candidates.count,
            selectedCandidate: selectedCandidate,
            words: words.map { w in
                .init(reading: w.reading, surface: w.surface, cost: w.cost, baseCost: w.baseCost,
                      pos: w.posNames.first ?? "", userOverride: w.userOverride, deleted: w.deleted,
                      inSelected: selectedIDs.contains(w.id), ambiguous: repeated.contains(w.surface))
            },
            connections: connections.map { k in
                .init(index: k.index, left: k.left ?? "BOS", right: k.right ?? "EOS", rid: k.rid, lid: k.lid,
                      leftPOS: k.leftPOS, rightPOS: k.rightPOS, cost: k.cost, baseCost: k.baseCost,
                      userOverride: k.userOverride, disabled: k.disabled)
            },
            connectionEditCount: editor?.dictionary.statistics.userConnectionEdits ?? 0,
            collocations: collocations.map { e in
                .init(left: e.left, right: e.right, negative: e.polarity == .negative,
                      active: e.polarity == .positive && candidates.contains { $0.collocations.contains(e.key) })
            },
            collocationChoices: collocationChoices,
            costStep: UserDict.costStep,
            costMax: UserDict.costRange.upperBound,
            collocationBonus: UserDict.collocationBonus
        )
    }

    public var stateJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
