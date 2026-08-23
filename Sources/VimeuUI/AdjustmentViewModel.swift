import Foundation
import VimeuEngine
import VimeuUserDict

/// State behind the tuning window.
///
/// Every action edits the user dictionary and immediately re-converts, so the
/// effect of a change is visible in the candidate list straight away. There is
/// no unsaved buffer: the undo path is リセット (drop the edit) and 復活 (unhide),
/// which are themselves edits.
public final class AdjustmentViewModel: ObservableObject {
    /// Which pane the window is showing. Held here rather than in the view
    /// because the switcher lives in the window's toolbar, outside it.
    public enum Tab: String, Hashable, CaseIterable, Sendable {
        case words, collocations, connections

        public var title: String {
            switch self {
            case .words: return "単語"
            case .collocations: return "共起"
            case .connections: return "接続"
            }
        }
    }

    @Published public var tab: Tab = .words
    @Published public var reading: String = ""
    @Published public private(set) var candidates: [Candidate] = []
    @Published public private(set) var words: [WordKnob] = []
    @Published public private(set) var message: String?

    /// Registered word pairs, and the menus for adding one.
    @Published public private(set) var collocations: [CollocationEdit] = []
    @Published public private(set) var collocationChoices: [String] = []
    @Published public var collocationPolarity: CollocationPolarity = .positive
    @Published public var collocationLeft: String = ""
    @Published public var collocationRight: String = ""

    /// Which candidate the 接続 pane is explaining. The word pane pools every
    /// candidate's entries, but a transition only means anything inside one
    /// path, so that pane needs a selection.
    @Published public var selectedCandidate: Int = 0

    /// Nil until the dictionary has been opened; the window then shows why.
    public var editor: DictionaryEditor? {
        didSet { reconvert() }
    }

    public init() {}

    /// Surfaces listed more than once in `words`.
    ///
    /// Entries are keyed by *(reading, surface)*, so one surface can appear
    /// several times — the shipped dictionary gives 隣 three readings. The list
    /// normally leaves the reading out, and shows it only on these rows, where
    /// it is the only thing telling them apart.
    public var ambiguousSurfaces: Set<String> {
        var seen = Set<String>()
        var repeated = Set<String>()
        for knob in words where !seen.insert(knob.surface).inserted {
            repeated.insert(knob.surface)
        }
        return repeated
    }

    /// The transitions of the selected candidate — the whole content of the
    /// 接続 pane, each with the edit state of the matrix cell behind it.
    ///
    /// Computed rather than published: it depends on `selectedCandidate`, which
    /// changes without a re-convert, and a candidate has a handful of boundaries.
    public var connections: [ConnectionKnob] {
        guard let editor, candidates.indices.contains(selectedCandidate) else { return [] }
        return editor.connectionKnobs(for: candidates[selectedCandidate])
    }

    public func show(reading: String?) {
        if let reading, !reading.isEmpty { self.reading = reading }
        reconvert()
    }

    public func reconvert() {
        guard let editor else {
            candidates = []
            words = []
            collocations = []
            collocationChoices = []
            message = "辞書が読み込まれていません"
            return
        }
        message = editor.lastError
        collocations = editor.collocations
        guard !reading.isEmpty else {
            candidates = []
            words = []
            collocationChoices = []
            return
        }
        // Which candidate the 接続 pane is explaining has to survive the
        // re-convert, and an edit is *meant* to move candidates around — holding
        // the index would leave the pane pointing at whatever landed in that row,
        // which is the candidate the user just demoted. Follow the text instead.
        let wasSelected = candidates.indices.contains(selectedCandidate)
            ? candidates[selectedCandidate].text : nil
        let converter = Converter(dictionary: editor.dictionary)
        // The word and collocation panes pool entries from every candidate.
        // Truncating this conversion would make valid dictionary entries
        // impossible to inspect or edit merely because their sentence ranked
        // below the visible top rows.
        candidates = converter.convert(reading: reading, limit: NBest.maxExpansions)
        if let wasSelected, let moved = candidates.firstIndex(where: { $0.text == wasSelected }) {
            selectedCandidate = moved
        } else if !candidates.indices.contains(selectedCandidate) {
            selectedCandidate = 0
        }
        // Cheapest first: the entries most likely to be responsible for a
        // conversion are the ones worth looking at.
        words = editor.wordKnobs(for: candidates, reading: reading)

        collocationChoices = editor.collocationChoices(for: candidates)
        // Keep a selection the user made, but never leave a menu showing a word
        // that is not in this sentence — after a re-convert that would register
        // a pair the user cannot see.
        if !collocationChoices.contains(collocationLeft) {
            collocationLeft = collocationChoices.first ?? ""
        }
        if !collocationChoices.contains(collocationRight) {
            collocationRight = collocationChoices.dropFirst().first ?? ""
        }
    }

    // MARK: - Word actions

    public func setCost(_ knob: WordKnob, to cost: Int32) {
        editor?.setWordCost(reading: knob.reading, surface: knob.surface, cost: cost)
        reconvert()
    }

    /// `steps > 0` is 強める, which lowers the cost — `DictionaryEditor` owns the
    /// sign so the view never has to think about it.
    public func boost(_ knob: WordKnob, steps: Int) {
        editor?.boostWord(reading: knob.reading, surface: knob.surface, steps: steps)
        reconvert()
    }

    public func delete(_ knob: WordKnob) {
        editor?.deleteWord(reading: knob.reading, surface: knob.surface)
        reconvert()
    }

    public func revive(_ knob: WordKnob) {
        editor?.reviveWord(reading: knob.reading, surface: knob.surface)
        reconvert()
    }

    public func reset(_ knob: WordKnob) {
        editor?.resetWord(reading: knob.reading, surface: knob.surface)
        reconvert()
    }

    public func addWord(reading: String, surface: String, cost: Int32) {
        guard !reading.isEmpty, !surface.isEmpty else { return }
        editor?.setWordCost(reading: reading, surface: surface, cost: cost)
        reconvert()
    }

    // MARK: - Connection actions

    /// The same five gestures as the word list, on a cell of the connection
    /// matrix. What differs is the reach, not the mechanics — see the pane's
    /// footer and DESIGN.md §4.2.
    public func setConnectionCost(_ knob: ConnectionKnob, to cost: Int32) {
        editor?.setConnectionCost(rid: knob.rid, lid: knob.lid, cost: cost)
        reconvert()
    }

    public func boostConnection(_ knob: ConnectionKnob, steps: Int) {
        editor?.boostConnection(rid: knob.rid, lid: knob.lid, steps: steps)
        reconvert()
    }

    public func disableConnection(_ knob: ConnectionKnob) {
        editor?.disableConnection(rid: knob.rid, lid: knob.lid)
        reconvert()
    }

    public func reviveConnection(_ knob: ConnectionKnob) {
        editor?.reviveConnection(rid: knob.rid, lid: knob.lid)
        reconvert()
    }

    public func resetConnection(_ knob: ConnectionKnob) {
        editor?.resetConnection(rid: knob.rid, lid: knob.lid)
        reconvert()
    }

    /// How many cells the user has moved, for the pane's footer. A count is the
    /// only honest global statement this window can make about connection edits:
    /// it cannot show what they did to the rest of the language.
    public var connectionEditCount: Int {
        editor?.dictionary.statistics.userConnectionEdits ?? 0
    }

    // MARK: - Collocation actions

    /// A pair only means something as an ordered pair of two different words, so
    /// the button that calls this is disabled until both menus are set and they
    /// differ.
    public var canAddCollocation: Bool {
        !collocationLeft.isEmpty && !collocationRight.isEmpty
            && collocationLeft != collocationRight
    }

    public func addCollocation() {
        guard canAddCollocation else { return }
        editor?.addCollocation(
            left: collocationLeft, right: collocationRight,
            polarity: collocationPolarity
        )
        reconvert()
    }

    public func removeCollocation(_ edit: CollocationEdit) {
        editor?.removeCollocation(left: edit.left, right: edit.right)
        reconvert()
    }

    /// Whether a registered pair is one the current candidates could ever use.
    ///
    /// The list holds every pair the user has ever registered, most of which
    /// have nothing to do with the sentence on screen. Marking the ones that do
    /// is what connects this pane back to the candidate list above it.
    public func isActive(_ edit: CollocationEdit) -> Bool {
        guard edit.polarity == .positive else { return false }
        return candidates.contains { $0.collocations.contains(edit.key) }
    }
}
