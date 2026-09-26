import SwiftUI
import AppKit
import VimeuEngine
import VimeuInput
import VimeuUserDict

/// The tuning window's content.
///
/// Layout follows the shape of the task: the reading and its candidates stay
/// pinned at the top, because every edit below is judged by what happens to
/// them, and the two panes — the words you can edit, and the transitions that
/// explain the ranking — sit behind tabs so only one list is on screen at a time.
///
/// Sizes and colours come from the system (`.body`, `.secondary`, `Table`,
/// `Form(.grouped)`) rather than hardcoded points, so the window matches the
/// current macOS look and follows the user's text-size and appearance settings.
public struct AdjustmentView: View {
    @ObservedObject var model: AdjustmentViewModel

    @State private var showAddWord = false
    /// The row ID currently requested by a candidate click. `Table` keeps its
    /// own native scroll view; the declarative position is kept in sync while
    /// the AppKit proxy below performs the actual row jump on macOS.
    @State private var wordScrollPosition = ScrollPosition(idType: WordKnob.ID.self)
    @State private var jumpCandidateText: String?
    @State private var nextJumpOrdinal = 0
    @State private var requestedWordID: WordKnob.ID?
    @State private var wordScrollRequest = 0

    public init(model: AdjustmentViewModel) {
        self.model = model
    }

    public var body: some View {
        // Pinned to the top: the reading and its candidates must not move when
        // the pane below changes size, so the panes take all remaining height
        // rather than letting the stack centre itself.
        VStack(spacing: 0) {
            if model.tab != .liveConversion {
                header
                Divider()
            }
            Group {
                switch model.tab {
                case .words: wordsTab
                case .collocations: collocationsTab
                case .connections: connectionsTab
                case .liveConversion: LiveConversionSettingsView()
                }
            }
            // Fills the rest of the window. Hugging the top instead left the
            // pane its natural height and the window's whole lower half as bare
            // background.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 660, minHeight: 520)
        // Lists live on the content background, not the window background —
        // that separation is what gives a macOS window its depth.
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showAddWord) {
            AddWordSheet { reading, surface, cost in
                model.addWord(reading: reading, surface: surface, cost: cost)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("ひらがなの読み", text: $model.reading)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit { model.reconvert() }
                // Not the default action: Return in the field already converts,
                // and a filled blue button here would be the loudest thing in
                // the window for something the user rarely clicks.
                Button("変換") { model.reconvert() }
                    .controlSize(.large)
            }

            if let message = model.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            if model.candidates.isEmpty {
                Text("読みを入力して変換すると、候補と、それを組み立てた辞書エントリが出ます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: CandidateCostGraph.emptyHeight, alignment: .top)
            } else {
                CandidateCostGraph(
                    candidates: model.candidates,
                    selectedCandidate: model.selectedCandidate,
                    onSelect: selectCandidateAndRequestWordJump
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Words

    private var wordsTab: some View {
        VStack(spacing: 0) {
            if model.words.isEmpty {
                ContentUnavailableView(
                    "単語がありません",
                    systemImage: "character.book.closed",
                    description: Text("変換すると、候補を組み立てた辞書エントリがここに並びます。")
                )
            } else {
                let ambiguous = model.ambiguousSurfaces
                // Calculate once per render: a candidate can have thousands of
                // pooled word rows, all of which consult this same path.
                let selectedWordIDs = model.selectedCandidateWordIDs
                Table(model.words) {
                    TableColumn("表記") { knob in
                        let isMatched = selectedWordIDs.contains(knob.id)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(knob.surface)
                                .strikethrough(knob.deleted)
                                .foregroundStyle(knob.deleted ? .secondary : .primary)
                            // Entries are keyed by (reading, surface), so the
                            // reading is shown only where two rows would
                            // otherwise be indistinguishable.
                            if ambiguous.contains(knob.surface) {
                                Text(knob.reading)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .wordMatchBackground(isMatched, leadingAccent: true)
                        .accessibilityLabel(
                            isMatched
                                ? "\(knob.surface)、選択中の候補に含まれる単語"
                                : knob.surface
                        )
                    }
                    // Mozc keys entries by POS and the same spelling can be
                    // registered under several, with different costs and
                    // different neighbours. Without this the rows are
                    // indistinguishable.
                    TableColumn("品詞") { knob in
                        let isMatched = selectedWordIDs.contains(knob.id)
                        Text(knob.posNames.map(Self.shortPOS).joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(knob.posNames.joined(separator: "\n"))
                            .wordMatchBackground(isMatched)
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("コスト") { knob in
                        let isMatched = selectedWordIDs.contains(knob.id)
                        CostField(
                            value: knob.cost,
                            base: knob.userOverride ? knob.baseCost : nil,
                            onSet: { model.setCost(knob, to: $0) }
                        )
                        .wordMatchBackground(isMatched)
                    }
                    .width(min: 120, ideal: 128)
                    TableColumn("") { knob in
                        let isMatched = selectedWordIDs.contains(knob.id)
                        KnobActions(
                            deleted: knob.deleted,
                            canReset: knob.userOverride || knob.deleted,
                            onBoost: { model.boost(knob, steps: $0) },
                            onDelete: { model.delete(knob) },
                            onRevive: { model.revive(knob) },
                            onReset: { model.reset(knob) }
                        )
                        .wordMatchBackground(isMatched)
                    }
                    .width(min: 132, ideal: 140)
                }
                .scrollPosition($wordScrollPosition, anchor: .center)
                // ScrollPosition remains attached to the Table as the view's
                // declarative scroll state. On macOS 27, Table is backed by
                // NSTableView and that modifier does not move the native row;
                // this proxy performs the actual jump without replacing Table.
                .background(
                    WordTableScrollProxy(
                        rowIDs: model.words.map(\.id),
                        targetID: requestedWordID,
                        request: wordScrollRequest
                    )
                )
            }
            Spacer(minLength: 0)
            TabFooter(
                hint: "コストは小さいほど優先されます（Mozc と同じ向き）。削除した語は「復活」で戻せます。",
                buttonTitle: "単語を追加",
                action: { showAddWord = true }
            )
        }
    }

    /// Select a candidate and advance through its highlighted word rows. The
    /// order follows the candidate's displayed segmentation, while the IDs
    /// still point at the corresponding rows in the word table.
    private func selectCandidateAndRequestWordJump(_ index: Int) {
        guard model.candidates.indices.contains(index) else { return }
        let candidateText = model.candidates[index].text
        model.selectedCandidate = index
        if jumpCandidateText != candidateText {
            jumpCandidateText = candidateText
            nextJumpOrdinal = 0
        }

        let wordIDs = Self.candidateWordIDsForJump(
            candidate: model.candidates[index],
            words: model.words
        )
        guard !wordIDs.isEmpty else { return }

        let target = wordIDs[nextJumpOrdinal % wordIDs.count]
        nextJumpOrdinal = (nextJumpOrdinal + 1) % wordIDs.count
        requestedWordID = target
        wordScrollRequest += 1
        wordScrollPosition.scrollTo(id: target, anchor: .center)
    }

    /// Converts the candidate's displayed segmentation into the IDs of the
    /// rows available in the word table. A table has one row per dictionary
    /// entry, so repeated use of the same entry in a candidate is collapsed.
    static func candidateWordIDsForJump(
        candidate: Candidate,
        words: [WordKnob]
    ) -> [WordKnob.ID] {
        let availableIDs = Set(words.map(\.id))
        var seen = Set<WordKnob.ID>()
        return candidate.segments.compactMap { segment in
            let id = segment.reading + "\t" + segment.surface
            guard availableIDs.contains(id), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// `名詞,固有名詞,人名,姓,*,*,*` → `名詞,固有名詞,人名,姓`.
    ///
    /// The trailing `*` components carry no information and are most of the
    /// string's width; the full feature stays in the tooltip.
    private static func shortPOS(_ feature: String) -> String {
        var parts = feature.split(separator: ",", omittingEmptySubsequences: false)
        while parts.count > 1, parts.last == "*" { parts.removeLast() }
        return parts.joined(separator: ",")
    }

    // MARK: - Collocations

    /// Word pairs the user wants chosen together.
    ///
    /// Two menus rather than two text fields, and both are filled from the words
    /// of the current candidates: a pair is only worth registering if it can
    /// actually fire on a sentence, and typing invites pairs that never will —
    /// a typo, an inflected form the lattice never produces, a word from another
    /// sentence entirely. Picking from what is on screen makes an unusable pair
    /// impossible to enter.
    ///
    /// Only content words are offered. `皮 を 剥く` is three words but the pair
    /// is 皮 × 剥く; putting `を` in the menu would offer a pair that cannot mean
    /// anything.
    private var collocationsTab: some View {
        VStack(spacing: 0) {
            collocationEditor
            Divider()
            if model.collocations.isEmpty {
                ContentUnavailableView(
                    "共起はありません",
                    systemImage: "link",
                    description: Text("正の共起は一緒に選ばれるようにし、"
                                      + "負の共起は同じ候補から除外します。")
                )
            } else {
                Table(model.collocations) {
                    TableColumn("種類") { pair in
                        Label(
                            pair.polarity.title,
                            systemImage: pair.polarity == .positive
                                ? "link" : "nosign"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            pair.polarity == .positive ? Color.primary : Color.orange
                        )
                    }
                    .width(min: 90, ideal: 100)
                    TableColumn("左") { pair in Text(pair.left) }
                    TableColumn("") { _ in
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    }
                    .width(20)
                    TableColumn("右") { pair in Text(pair.right) }
                    // The list outlives any one sentence, so most rows have
                    // nothing to do with what is on screen. This column is what
                    // ties the two together.
                    TableColumn("状態") { pair in
                        if pair.polarity == .negative {
                            Label("候補から除外", systemImage: "nosign")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if model.isActive(pair) {
                            Label("有効", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("") { pair in
                        Button { model.removeCollocation(pair) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("この組を削除")
                    }
                    .width(40)
                }
            }
            Spacer(minLength: 0)
            CollocationFooter(bonus: UserDict.collocationBonus)
        }
    }

    private var collocationEditor: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.collocationChoices.isEmpty {
                Text("変換すると、この文に出てくる自立語がここから選べます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                Picker("種類", selection: $model.collocationPolarity) {
                    ForEach(CollocationPolarity.allCases, id: \.self) { polarity in
                        Text(polarity.title).tag(polarity)
                    }
                }
                .frame(minWidth: 100)
                wordMenu(selection: $model.collocationLeft)
                Image(
                    systemName: model.collocationPolarity == .positive
                        ? "arrow.right" : "nosign"
                )
                .foregroundStyle(
                    model.collocationPolarity == .positive ? Color.secondary : Color.orange
                )
                wordMenu(selection: $model.collocationRight)
                Spacer(minLength: 12)
                Button("組を追加", systemImage: "plus") { model.addCollocation() }
                    .disabled(!model.canAddCollocation)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func wordMenu(selection: Binding<String>) -> some View {
        // Labelless: the arrow between the two menus already says which is
        // which, and a "左"/"右" label on each would be three words of chrome for
        // a two-item row.
        Picker("", selection: selection) {
            ForEach(model.collocationChoices, id: \.self) { word in
                Text(word).tag(word)
            }
        }
        .labelsHidden()
        .frame(minWidth: 120)
    }

    // MARK: - Connections

    /// Why the selected candidate won — and, since the edits landed, where to
    /// change it.
    ///
    /// The controls are deliberately the same five as the word list: the user
    /// already knows 強める / 弱める / 数値 / 使わない / リセット, and a transition
    /// is one more number in the same units. What is *not* the same is the reach.
    /// A word edit touches the sentences that word appears in; this touches every
    /// sentence in the language that crosses this pair of parts of speech, and
    /// this window can only ever show one of them. That is what the footer says,
    /// and why DESIGN.md §4.2 points at `vimeu-eval --user` — the effect on the
    /// other 13,804 sentences is measurable, just not from here.
    private var connectionsTab: some View {
        let connections = model.connections
        return VStack(spacing: 0) {
            if connections.isEmpty {
                ContentUnavailableView(
                    "接続はありません",
                    systemImage: "arrow.left.arrow.right",
                    description: Text("変換して候補を選ぶと、その候補の語と語のつながりに"
                                      + "かかったコストがここに並びます。")
                )
            } else {
                Table(connections) {
                    TableColumn("左") { knob in
                        boundarySide(
                            surface: knob.left ?? "BOS",
                            pos: knob.leftPOS,
                            isTerminal: knob.left == nil,
                            disabled: knob.disabled
                        )
                    }
                    TableColumn("") { _ in
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    }
                    .width(20)
                    TableColumn("右") { knob in
                        boundarySide(
                            surface: knob.right ?? "EOS",
                            pos: knob.rightPOS,
                            isTerminal: knob.right == nil,
                            disabled: knob.disabled
                        )
                    }
                    TableColumn("接続コスト") { knob in
                        CostField(
                            value: knob.cost,
                            base: knob.userOverride || knob.disabled ? knob.baseCost : nil,
                            onSet: { model.setConnectionCost(knob, to: $0) }
                        )
                    }
                    .width(min: 120, ideal: 128)
                    TableColumn("") { knob in
                        KnobActions(
                            deleted: knob.disabled,
                            canReset: knob.userOverride || knob.disabled,
                            onBoost: { model.boostConnection(knob, steps: $0) },
                            onDelete: { model.disableConnection(knob) },
                            onRevive: { model.reviveConnection(knob) },
                            onReset: { model.resetConnection(knob) }
                        )
                    }
                    .width(min: 132, ideal: 140)
                }
            }
            Spacer(minLength: 0)
            ConnectionFooter(
                total: connections.reduce(0) { $0 + $1.cost },
                editCount: model.connectionEditCount
            )
        }
    }

    private func boundarySide(
        surface: String, pos: String, isTerminal: Bool, disabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(surface)
                .strikethrough(disabled)
                .foregroundStyle(isTerminal || disabled ? .secondary : .primary)
            Text(Self.shortPOS(pos))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(pos)
    }
}

/// The graph above the dictionary tables. The chart keeps the candidate text
/// split into its dictionary entries, while making the three numbers that
/// explain the ranking visible at the same time.
private enum CandidateGraphLayout {
    static let totalColumnWidth: CGFloat = 78
    static let columnSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 6

    /// Give the candidate label twice the width of the graph, after reserving
    /// the fixed total column and the two column gaps.
    static func columns(in width: CGFloat) -> (label: CGFloat, graph: CGFloat) {
        let fixed = horizontalPadding * 2
            + totalColumnWidth
            + columnSpacing * 2
        let flexible = max(0, width - fixed)
        let graph = flexible / 3
        return (label: flexible - graph, graph: graph)
    }
}

private struct CandidateCostGraph: View {
    static let emptyHeight: CGFloat = 150

    private static let visibleRowCount = 5
    private static let axisHeight: CGFloat = 18
    private static let breakdownRowHeight: CGFloat = 30

    let candidates: [Candidate]
    let selectedCandidate: Int
    let onSelect: (Int) -> Void

    private var showsCollocationCost: Bool {
        candidates.contains { $0.collocationCost != 0 }
    }

    /// The axis is derived from the current candidates, so the graph remains
    /// useful for both ordinary Mozc-sized costs and the maximum user-editable
    /// cost without hiding the actual differences in a fixed range.
    private var scaleMaximum: Int64 {
        let observed = candidates.reduce(Int64(0)) { current, candidate in
            let wordAndConnection = Int64(candidate.wordCost) + Int64(candidate.connectionCost)
            let values = [
                Int64(candidate.cost),
                Int64(candidate.wordCost),
                Int64(candidate.connectionCost),
                wordAndConnection
            ]
            return max(current, values.max() ?? 0)
        }
        return Self.niceUpperBound(max(0, observed))
    }

    private var scaleMarks: [Int64] {
        let midpoint = scaleMaximum / 2
        return midpoint > 0
            ? [0, midpoint, scaleMaximum]
            : [0, scaleMaximum]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("変換候補")
                    .font(.headline)
                Spacer(minLength: 8)
                Text("コストは小さいほど優先")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("候補ごとのコスト内訳")
                    .font(.callout)
                    .fontWeight(.medium)
                Text(formulaText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                legendItem(
                    color: .secondary,
                    label: "合計（末端）",
                    outlined: true
                )
                legendItem(color: .accentColor, label: "単語")
                legendItem(color: Color(nsColor: .systemPurple), label: "接続")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    axisRow
                    ForEach(candidates.indices, id: \.self) { index in
                        CandidateCostGraphRow(
                            index: index,
                            candidate: candidates[index],
                            isSelected: selectedCandidate == index,
                            scaleMaximum: scaleMaximum,
                            onSelect: { onSelect(index) }
                        )
                        .frame(height: Self.breakdownRowHeight)
                    }
                }
            }
            // Keep a stable five-row viewport. The reading field does not jump
            // when a conversion changes the number of candidates.
            .frame(
                height: Self.breakdownRowHeight * CGFloat(Self.visibleRowCount)
                    + Self.axisHeight
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var formulaText: String {
        showsCollocationCost
            ? "合計 = 単語 + 接続 + 共起（共起がない候補では 0）"
            : "合計 = 単語 + 接続"
    }

    private var axisRow: some View {
        GeometryReader { proxy in
            let columns = CandidateGraphLayout.columns(in: proxy.size.width)
            HStack(spacing: CandidateGraphLayout.columnSpacing) {
                Text("候補")
                    .frame(width: columns.label, alignment: .leading)

                HStack(spacing: 0) {
                    ForEach(Array(scaleMarks.enumerated()), id: \.offset) { index, mark in
                        Text("\(mark)")
                            .frame(maxWidth: .infinity, alignment: axisAlignment(for: index))
                    }
                }
                .frame(width: columns.graph)

                Text("合計")
                    .frame(width: CandidateGraphLayout.totalColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, CandidateGraphLayout.horizontalPadding)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .monospacedDigit()
        .frame(height: Self.axisHeight)
    }

    private func axisAlignment(for index: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == scaleMarks.count - 1 { return .trailing }
        return .center
    }

    private func legendItem(color: Color, label: String, outlined: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(outlined ? Color.clear : color)
                .overlay {
                    if outlined {
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(color, lineWidth: 1)
                    }
                }
                .frame(width: 9, height: 9)
            Text(label)
        }
    }

    private static func niceUpperBound(_ value: Int64) -> Int64 {
        guard value > 0 else { return 1 }
        let magnitude = pow(10.0, floor(log10(Double(value))))
        let normalized = Double(value) / magnitude
        let nice: Double
        switch normalized {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...5: nice = 5
        default: nice = 10
        }
        return max(1, Int64(ceil(nice * magnitude)))
    }
}

private struct CandidateCostGraphRow: View {
    let index: Int
    let candidate: Candidate
    let isSelected: Bool
    let scaleMaximum: Int64
    let onSelect: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = CandidateGraphLayout.columns(in: proxy.size.width)
            Button(action: onSelect) {
                HStack(spacing: CandidateGraphLayout.columnSpacing) {
                    HStack(spacing: 6) {
                        Text("\(index + 1)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 17, alignment: .trailing)
                        Text(candidate.segments.map(\.surface).joined(separator: " · "))
                            .fontWeight(isSelected ? .semibold : .regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: columns.label, alignment: .leading)

                    CandidateCostGraphBar(
                        candidate: candidate,
                        scaleMaximum: scaleMaximum
                    )
                    .frame(width: columns.graph)

                    HStack(spacing: 3) {
                        Text("合計")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(candidate.cost)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    .frame(width: CandidateGraphLayout.totalColumnWidth, alignment: .trailing)
                }
                .padding(.horizontal, CandidateGraphLayout.horizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
        .contentShape(Rectangle())
        .help(costTooltip)
        .accessibilityLabel(
            Text(candidate.segments.map(\.surface).joined(separator: "、"))
        )
        .accessibilityValue(Text(accessibilityCost))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityCost: String {
        var text = "合計 \(candidate.cost)、単語 \(candidate.wordCost)、接続 \(candidate.connectionCost)"
        if candidate.collocationCost != 0 {
            text += "、共起 \(candidate.collocationCost)"
        }
        return text
    }

    private var costTooltip: String {
        var text = "合計 \(candidate.cost) ＝ 単語 \(candidate.wordCost)"
            + " ＋ 接続 \(candidate.connectionCost)"
        if candidate.collocationCost != 0 {
            text += " ＋ 共起 \(candidate.collocationCost)"
        }
        text += "（コストは小さいほど優先）"
        return text
    }
}

private struct CandidateCostGraphBar: View {
    let candidate: Candidate
    let scaleMaximum: Int64

    private var wordColor: Color { .accentColor }
    private var connectionColor: Color { Color(nsColor: .systemPurple) }

    var body: some View {
        GeometryReader { proxy in
            breakdownBar(availableWidth: proxy.size.width)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    private func breakdownBar(availableWidth: CGFloat) -> some View {
        let wordWidth = width(for: candidate.wordCost, available: availableWidth)
        let connectionWidth = width(for: candidate.connectionCost, available: availableWidth)
        let totalPosition = width(for: candidate.cost, available: availableWidth)

        return ZStack(alignment: .leading) {
            track(width: availableWidth, height: 18)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(wordColor)
                    .frame(width: wordWidth, height: 18)
                Rectangle()
                    .fill(connectionColor)
                    .frame(width: connectionWidth, height: 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle()
                .fill(Color.secondary)
                .frame(width: 1, height: 20)
                .offset(x: min(max(totalPosition, 0), max(availableWidth - 1, 0)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func track(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
            HStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 1)
                    if index < 4 { Spacer(minLength: 0) }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func width(for value: Int32, available: CGFloat) -> CGFloat {
        guard scaleMaximum > 0, available > 0 else { return 0 }
        let ratio = min(max(Double(value) / Double(scaleMaximum), 0), 1)
        return available * ratio
    }
}

/// A zero-sized AppKit view used to reach the native table behind SwiftUI's
/// `Table`. SwiftUI's `ScrollPosition` API currently updates a ScrollView but
/// does not move the NSTableView that renders a macOS Table, so the native
/// `scrollRowToVisible` operation is needed for this one interaction.
private struct WordTableScrollProxy: NSViewRepresentable {
    let rowIDs: [WordKnob.ID]
    let targetID: WordKnob.ID?
    let request: Int

    func makeNSView(context: Context) -> WordTableScrollAnchor {
        WordTableScrollAnchor()
    }

    func updateNSView(_ nsView: WordTableScrollAnchor, context: Context) {
        nsView.update(rowIDs: rowIDs, targetID: targetID, request: request)
    }
}

private final class WordTableScrollAnchor: NSView {
    private var rowIDs: [WordKnob.ID] = []
    private var targetID: WordKnob.ID?
    private var request = 0
    private var scheduledRequest: Int?
    private var retryCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isHidden = true
    }

    func update(rowIDs: [WordKnob.ID], targetID: WordKnob.ID?, request: Int) {
        self.rowIDs = rowIDs
        self.targetID = targetID
        if self.request != request {
            retryCount = 0
        }
        self.request = request
        scheduleScroll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleScroll()
    }

    private func scheduleScroll() {
        guard targetID != nil, window != nil else { return }
        guard scheduledRequest != request else { return }
        scheduledRequest = request
        let request = request
        DispatchQueue.main.async { [weak self] in
            self?.performScroll(for: request)
        }
    }

    private func performScroll(for request: Int) {
        scheduledRequest = nil
        guard request == self.request,
              let targetID,
              let row = rowIDs.firstIndex(of: targetID)
        else { return }

        guard let table = findTable(in: window?.contentView) else {
            // SwiftUI can create this proxy one layout pass before Table's
            // NSTableView. Retry briefly, but never leave a timer running.
            guard retryCount < 8 else { return }
            retryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.scheduleScroll()
            }
            return
        }

        guard row < table.numberOfRows else {
            guard retryCount < 8 else { return }
            retryCount += 1
            DispatchQueue.main.async { [weak self] in
                self?.scheduleScroll()
            }
            return
        }
        // NSTableView guarantees visibility; centering the row afterwards makes
        // repeated clicks visibly advance even when both rows were nearby.
        table.scrollRowToVisible(row)
        guard let scrollView = table.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let rowRect = table.rect(ofRow: row)
        let maxOriginY = max(0, table.bounds.height - clipView.bounds.height)
        let centeredOriginY = max(
            0,
            min(rowRect.midY - clipView.bounds.height / 2, maxOriginY)
        )
        clipView.setBoundsOrigin(
            NSPoint(x: clipView.bounds.origin.x, y: centeredOriginY)
        )
        scrollView.reflectScrolledClipView(clipView)
    }

    private func findTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }
}

private extension View {
    /// A quiet, full-row cue that connects a selected candidate to the exact
    /// dictionary entries that made it.  Semantic system colours preserve the
    /// contrast in both light and dark appearances.
    @ViewBuilder
    func wordMatchBackground(_ isMatched: Bool, leadingAccent: Bool = false) -> some View {
        if isMatched {
            self
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, leadingAccent ? 4 : 0)
                .background(Color(nsColor: .selectedContentBackgroundColor).opacity(0.18))
                .overlay(alignment: .leading) {
                    if leadingAccent {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 3)
                    }
                }
        } else {
            self
        }
    }
}

// MARK: - Pieces

/// The hint line and "add" button of the word tab.
private struct TabFooter: View {
    let hint: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        Divider()
        HStack(alignment: .firstTextBaseline) {
            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(buttonTitle, systemImage: "plus", action: action)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

private struct CollocationFooter: View {
    let bonus: Int32

    var body: some View {
        Divider()
        Text("正の共起を満たす候補は、合計コストから \(bonus) 引かれます。"
             + "負の共起を含む候補は、コストに関係なく除外されます。"
             + "どちらも自立語どうしで、負の共起は語順を問いません。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
    }
}

/// The connection pane's footer.
///
/// The warning is not decoration. Everywhere else in this window an edit is
/// visible in the candidate list above it, and that list is the whole truth of
/// what changed. Here it is not: the row moved a rule of the grammar, and the
/// sentences it also moved are not on screen. Saying so — and naming the tool
/// that can show them — is the only thing the window can honestly do.
private struct ConnectionFooter: View {
    let total: Int32
    /// How many cells the user has moved in all, not just in this sentence.
    let editCount: Int

    var body: some View {
        Divider()
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("品詞と品詞のつながりにかかるコストです。この編集は品詞の組そのものに"
                     + "効くので、いま見えている文だけでなく、同じ組を通るすべての文が動きます。")
                Text("影響は vimeu-eval --user をテストセットに掛けて、編集前と比べてください。"
                     + (editCount > 0 ? "　編集済み \(editCount) 組" : ""))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Text("合計 \(total)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

/// An editable word cost.
private struct CostField: View {
    let value: Int32
    /// The system dictionary's value, shown only while an override hides it.
    let base: Int32?
    let onSet: (Int32) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 62)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { text = "\(value)" }
                .onChange(of: value) { _, new in if !focused { text = "\(new)" } }
            if let base {
                Text("\(base)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("元の値")
            }
        }
    }

    private func commit() {
        guard let parsed = Int32(text.trimmingCharacters(in: .whitespaces)) else {
            text = "\(value)"
            return
        }
        let clamped = UserDict.clampCost(parsed)
        text = "\(clamped)"
        if clamped != value { onSet(clamped) }
    }
}

private struct KnobActions: View {
    let deleted: Bool
    let canReset: Bool
    /// Positive steps mean 強める. The cost goes *down*; the model owns that sign
    /// so this view can stay in the user's vocabulary.
    let onBoost: (Int) -> Void
    let onDelete: () -> Void
    let onRevive: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            // Arrows, not ± — the user is moving a word up or down the
            // candidate list, and 強める *lowers* the number, so a plus sign
            // sits on the button that makes the cost go down. Up and down carry
            // the meaning without ever pointing at the number's direction.
            Button { onBoost(1) } label: { Image(systemName: "arrow.up") }
                .help("強める（順位を上げる。コストは下がる）")
                .disabled(deleted)
            Button { onBoost(-1) } label: { Image(systemName: "arrow.down") }
                .help("弱める（順位を下げる。コストは上がる）")
                .disabled(deleted)
            if deleted {
                Button { onRevive() } label: { Image(systemName: "eye") }
                    .help("復活")
            } else {
                Button { onDelete() } label: { Image(systemName: "eye.slash") }
                    .help("変換に出さない")
            }
            Button { onReset() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("編集を取り消して辞書の値に戻す")
                .disabled(!canReset)
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }
}

// MARK: - Sheets

private struct AddWordSheet: View {
    let onAdd: (String, String, Int32) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var reading = ""
    @State private var surface = ""
    /// Well below the shipped dictionary's typical 3000–8000, so a word the user
    /// bothered to add actually wins the first time they try it.
    @State private var cost = "1000"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("単語を追加").font(.headline)
            Form {
                TextField("読み", text: $reading, prompt: Text("ひらがな"))
                TextField("表記", text: $surface)
                TextField("コスト", text: $cost)
                Text("コストは小さいほど優先されます。辞書の語はおおむね 3000〜8000 です。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("追加") {
                    onAdd(reading, surface, Int32(cost) ?? 1000)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reading.isEmpty || surface.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

private struct LiveConversionSettingsView: View {
    @AppStorage(LiveConversionSettings.delayKey) private var delay = LiveConversionSettings.defaultDelay
    @AppStorage(LiveConversionSettings.autoCommitEnabledKey) private var autoCommitEnabled = false
    @AppStorage(LiveConversionSettings.autoCommitDelayKey) private var autoCommitDelay = LiveConversionSettings.defaultAutoCommitDelay
    @State private var text = ""
    @State private var invalid = false
    @State private var autoCommitText = ""
    @State private var autoCommitInvalid = false
    @FocusState private var focused: Bool
    @FocusState private var autoCommitFocused: Bool

    var body: some View {
        Form {
            Section("変換を開始するタイミング") {
                HStack {
                    Text("キー入力を停止してから")
                    TextField("待ち時間", text: $text)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 100)
                        .focused($focused)
                        .onSubmit(commit)
                        .onChange(of: focused) { _, value in if !value { commit() } }
                    Text("ms 後に変換を開始")
                }
                if invalid {
                    Text("0〜60000 の整数を入力してください。設定は変更されていません。")
                        .foregroundStyle(.red)
                }
            }
            Section("自動確定") {
                Toggle("変換後に自動で確定する", isOn: $autoCommitEnabled)
                HStack {
                    Text("変換された文字列の表示から")
                    TextField("確定までの時間", text: $autoCommitText)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 100)
                        .focused($autoCommitFocused)
                        .onSubmit(commitAutoCommitDelay)
                        .onChange(of: autoCommitFocused) { _, value in
                            if !value { commitAutoCommitDelay() }
                        }
                    Text("ms 後に確定")
                }
                .disabled(!autoCommitEnabled)
                if autoCommitInvalid {
                    Text("100〜60000 の整数を入力してください。設定は変更されていません。")
                        .foregroundStyle(.red)
                }
                Text("入力が続くと待ち時間をやり直します。候補の選択中は自動確定しません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            text = String(LiveConversionSettings.clamp(delay))
            autoCommitText = String(LiveConversionSettings.clampAutoCommitDelay(autoCommitDelay))
        }
        .onDisappear {
            commit()
            commitAutoCommitDelay()
        }
    }

    private func commit() {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)),
              LiveConversionSettings.delayRange.contains(value) else {
            invalid = true
            return
        }
        delay = value
        text = String(value)
        invalid = false
    }

    private func commitAutoCommitDelay() {
        guard let value = Int(autoCommitText.trimmingCharacters(in: .whitespaces)),
              LiveConversionSettings.autoCommitDelayRange.contains(value) else {
            autoCommitInvalid = true
            return
        }
        autoCommitDelay = value
        autoCommitText = String(value)
        autoCommitInvalid = false
    }
}
