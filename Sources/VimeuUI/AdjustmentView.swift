import SwiftUI
import VimeuEngine
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

    public init(model: AdjustmentViewModel) {
        self.model = model
    }

    public var body: some View {
        // Pinned to the top: the reading and its candidates must not move when
        // the pane below changes size, so the panes take all remaining height
        // rather than letting the stack centre itself.
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.tab {
                case .words: wordsTab
                case .collocations: collocationsTab
                case .connections: connectionsTab
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

            // One fixed height either way, and a whole number of rows, so the
            // list never ends on a half-drawn row and nothing above it moves
            // when a conversion arrives.
            Group {
                if model.candidates.isEmpty {
                    Text("読みを入力して変換すると、候補と、それを組み立てた辞書エントリが出ます。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let showsCollocationCost = model.candidates.contains {
                        $0.collocationCost != 0
                    }
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.candidates.indices, id: \.self) { index in
                                candidateRow(
                                    index: index,
                                    candidate: model.candidates[index],
                                    showsCollocationCost: showsCollocationCost
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: Self.candidateRowHeight * 5)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private static let candidateRowHeight: CGFloat = 22

    /// A candidate, shown as its segmentation.
    ///
    /// Only the split form: the pieces are exactly the dictionary entries the
    /// candidate was built from and the rows of the 単語 pane below, so showing
    /// the plain string alongside it would say the same thing twice.
    ///
    /// Selecting a row is what the 接続 pane explains, so the whole row is a
    /// button rather than the tap target being some small affordance.
    private func candidateRow(
        index: Int,
        candidate: Candidate,
        showsCollocationCost: Bool
    ) -> some View {
        Button {
            model.selectedCandidate = index
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1)")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .trailing)
                Text(candidate.segments.map(\.surface).joined(separator: " · "))
                    .fontWeight(index == 0 ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 12)
                // 合計 = 単語 + 接続 + 共起, exactly.
                costCell("合計", candidate.cost, emphasised: true)
                costCell("単語", candidate.wordCost)
                costCell("接続", candidate.connectionCost)
                // Only once a pair is in play. Until then the column would be a
                // row of zeros explaining a feature the user has not used.
                if showsCollocationCost {
                    costCell("共起", candidate.collocationCost)
                }
            }
            .frame(height: Self.candidateRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            model.selectedCandidate == index
                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25)
                : Color.clear
        )
        .help(costTooltip(for: candidate, showsCollocationCost: showsCollocationCost))
    }

    private func costTooltip(for candidate: Candidate, showsCollocationCost: Bool) -> String {
        var text = "合計 \(candidate.cost) ＝ 単語 \(candidate.wordCost)"
            + " ＋ 接続 \(candidate.connectionCost)"
        if showsCollocationCost {
            text += " ＋ 共起 \(candidate.collocationCost)"
        }
        text += "（コストは小さいほど優先）"
        if !candidate.collocations.isEmpty {
            text += "\n共起: " + candidate.collocations
                .map { "\($0.left) → \($0.right)" }
                .joined(separator: "、")
        }
        return text
    }

    private func costCell(_ label: String, _ value: Int32, emphasised: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text("\(value)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(emphasised ? .secondary : .tertiary)
        }
        .frame(width: 66, alignment: .trailing)
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
                Table(model.words) {
                    TableColumn("表記") { knob in
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
                    }
                    // Mozc keys entries by POS and the same spelling can be
                    // registered under several, with different costs and
                    // different neighbours. Without this the rows are
                    // indistinguishable.
                    TableColumn("品詞") { knob in
                        Text(knob.posNames.map(Self.shortPOS).joined(separator: " / "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(knob.posNames.joined(separator: "\n"))
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("コスト") { knob in
                        CostField(
                            value: knob.cost,
                            base: knob.userOverride ? knob.baseCost : nil,
                            onSet: { model.setCost(knob, to: $0) }
                        )
                    }
                    .width(min: 120, ideal: 128)
                    TableColumn("") { knob in
                        KnobActions(
                            deleted: knob.deleted,
                            canReset: knob.userOverride || knob.deleted,
                            onBoost: { model.boost(knob, steps: $0) },
                            onDelete: { model.delete(knob) },
                            onRevive: { model.revive(knob) },
                            onReset: { model.reset(knob) }
                        )
                    }
                    .width(min: 132, ideal: 140)
                }
            }
            Spacer(minLength: 0)
            TabFooter(
                hint: "コストは小さいほど優先されます（Mozc と同じ向き）。削除した語は「復活」で戻せます。",
                buttonTitle: "単語を追加",
                action: { showAddWord = true }
            )
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
                    description: Text("一緒に選ばれてほしい2語を上で登録すると、"
                                      + "その組を満たす候補が上位に来ます。")
                )
            } else {
                Table(model.collocations) {
                    TableColumn("左") { pair in Text(pair.left) }
                    TableColumn("") { _ in
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                    }
                    .width(20)
                    TableColumn("右") { pair in Text(pair.right) }
                    // The list outlives any one sentence, so most rows have
                    // nothing to do with what is on screen. This column is what
                    // ties the two together.
                    TableColumn("この文") { pair in
                        if model.isActive(pair) {
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
                wordMenu(selection: $model.collocationLeft)
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
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
        Text("登録した組を満たす候補は、合計コストから \(bonus) 引かれます。"
             + "効くのは上位候補どうしの差を埋める範囲だけで、"
             + "大きく負けている候補は繰り上がりません。")
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
