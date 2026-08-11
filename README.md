# vimeu

macOS 向けのかな漢字変換 IME。**単一プロセスの純 Swift 実装**で、外部パッケージ依存はない。

**Mozc の辞書と接続コスト行列をそのまま使い、変換コストの計算を Mozc と同一にする。**
rewriter・予測変換・学習といった付加的な変換ロジックは持たない。

前身の [shimei](../shimei) からはプロセス構成・UI・ローマ字入力・ユーザー辞書の骨格を引き継ぎ、
変換方式（PMI 共起）と辞書フォーマットを作り直した。設計の詳細は [DESIGN.md](DESIGN.md)。

## 特徴

- **Mozc と同じコスト計算** — 単語コスト + 品詞連接コストの Viterbi。自由パラメータは無い。
- **文全体の n-best 変換** — 前向き Viterbi + 後ろ向き A* で厳密な k-best。文節境界の操作は持たない。
- **ライブ変換** — 入力しながら変換結果をインライン表示。
- **mmap 辞書** — 起動時のパースなし。常駐メモリは実際に触れたページのみ。
- **ユーザー辞書と調整ウィンドウ** — 自動学習は持たない。変換を変えたければ、単語コストを自分で編集する。
  編集は人が読める TSV に保存され、システム辞書を作り直しても生き残る。
- **サンドボックス対応** — 2026 の macOS 入力メソッド指針に沿った構成。

## 精度

同一のテストセットで shimei と比較した実測値。vimeu は Mozc UT 辞書 490 万行を**使っていない**
（理由は [DESIGN.md](DESIGN.md) §2.1）ことに注意。

| | Wikipedia (13,804文) | 会話文 (11,542文) |
|---|---|---|
| shimei 文字精度 | 70.89% | 72.91% |
| **vimeu 文字精度** | **84.47%** | **89.44%** |
| shimei 文精度 | 27.27% | 16.43% |
| **vimeu 文精度** | **34.63%** | **40.76%** |

Mozc 自身の回帰データ（`data/dictionary_oss/evaluation.tsv` のうち Mozc が `OK:` と記録している
429 件）では文精度 **91.14%**。

## 動作環境

macOS 14 以降。ビルドには Swift 6.2 以降（Xcode コマンドラインツール）が必要。

## 辞書データの用意

必要なのは **Mozc の `src/data` ディレクトリのコピーだけ**で、前処理は要らない。
使うのは次の 4 種で、すべてプレーンテキストである（Apache-2.0）。

```
dictionary_oss/dictionary00..09.txt        読み・品詞ID・コスト・表層
dictionary_oss/id.def                      2672 品詞
dictionary_oss/connection_single_column.txt 2672² の接続コスト
rules/boundary.def                         文頭・文末のペナルティ
```

```sh
git clone --depth 1 https://github.com/google/mozc.git /tmp/mozc
cp -R /tmp/mozc/src/data dict/mozc
```

チェックアウトを直接指してもよい（コピーすら要らない）:

```sh
make dict MOZC_DATA=/path/to/mozc/src/data
```

> Mozc UT 辞書（`mozcdic-ut-*`）は既定では使わない。全行の品詞 ID が `0000`（＝BOS/EOS）で、
> 接続コストを引けないため。どうしても使うなら
> `vimeu-dictbuild pack --extra '<glob>' --extra-pos <id>` で既定品詞を割り当てて取り込めるが、
> 精度は落ちる。

## ビルドとインストール

```sh
make install
```

辞書（`dict/vimeu.dic`）が無ければ自動で生成される（約 4 秒、52MB）。

インストール後、**システム設定 → キーボード → 入力ソース**で「vimeu」を追加する
（すでに追加済みなら一度切り替えると新しい版が読み込まれる）。

サンドボックスを外して調べたいときは `make install ENTITLEMENTS=` とする。

## 操作方法

かなモードでローマ字入力する。

| 状態 | キー | 動作 |
|---|---|---|
| 入力中 | ローマ字 | 読みを入力（ライブ変換オン時は変換結果をインライン表示） |
| 入力中 | `Space` | 変換を開始（候補選択へ） |
| 入力中 | `Enter` | 読み（またはライブ変換の結果）をそのまま確定 |
| 入力中 | `Delete` | 一文字削除 |
| 入力中 | `Esc` | 入力を全取消 |
| 入力中 | `,` / `.` | `、` / `。` |
| 候補選択中 | `↓` / `Space` | 次の候補 |
| 候補選択中 | `↑` | 前の候補 |
| 候補選択中 | `1`〜`9` | 番号で直接選んで確定 |
| 候補選択中 | `Enter` | 選択中の候補を確定 |
| 候補選択中 | `Esc` / `Delete` | 変換を取り消して入力中へ戻る |

## 変換の調整

メニューバーの入力メニュー（入力ソースのアイコン）から操作する。

- **ライブ変換** — 入力しながらの変換表示をオン/オフ。
- **調整...** — 調整ウィンドウを開く。開いた時点で編集中の読みが入っているので、
  おかしな変換に出会ったその文脈のまま調整に入れる。

ペインの切替はウィンドウ上部のツールバー（**単語 / 共起 / 接続**）。
読みと候補はその下に常に出ていて、ペインを切り替えても位置は動かない。

| | 操作 |
|---|---|
| **候補**（常時表示） | n-best を分割した形と、コストの内訳。行をクリックすると「接続」の説明対象になる |
| **単語** | コスト昇順に一覧。強める / 弱める / 直接編集 / 削除（復活）/ リセット。辞書に無い語の追加 |
| **共起** | 一緒に選ばれてほしい2語をドロップダウンで選んで登録。登録済みの一覧と削除 |
| **接続** | 選択中の候補の各境界の接続コスト（**読み取り専用**） |

候補行のコストは **合計 / 単語 / 接続** で、`合計 = 単語 + 接続` が厳密に成り立つ。
**コストは小さいほど優先**される（Mozc と同じ向き）。したがって「強める」はコストを下げる。

- **単語** = Σ 単語コスト（文頭・文末のペナルティ込み）
- **接続** = Σ 接続コスト（BOS/EOS の遷移を含む）
- **共起** = 登録したペアぶんの割引（登録するまでは列ごと出ない）

単語の一覧は表記と品詞を出す。品詞を出すのは、Mozc のエントリが品詞で意味が変わるためで、
同じ表記が複数行に出るときはさらに読みを添えて区別する。

「削除」はシステム辞書にある語なら**無効化**なので「復活」で戻せる。自分で追加した語は
行ごと消える。「リセット」は編集を捨ててシステム辞書の値に戻す。

### 共起

`かわをむく` が `川を向く` になるのは、`川` と `皮` の単語コスト差が 15 しかなく、品詞列が
どちらも 名詞 → 助詞 → 動詞 で接続コストが同じだからで、辞書のどこにも「剥かれるのは皮だ」とは
書かれていない。**共起**ペインはそれを1行で言うための場所である。

ドロップダウンで `皮` → `剥く` を選んで「組を追加」すると、その組を満たす候補が 3453 だけ
安くなる。選択肢は現在の全候補の**自立語**（助詞は出ない）で、いま画面にある語しか選べない
— 発火しようのないペアを登録できないようにするためである。

効くのはトップ候補から 3453 以内の候補までで、大きく負けている候補は繰り上がらない。
組を登録すると n-best を深く掘るようになるので、変換は遅くなる（[DESIGN.md](DESIGN.md) §3.5）。

**接続コストは編集できない。** 品詞ペアのコストは日本語のすべての文に効くので、1 文を直した
つもりで他が壊れる。その影響を同時に見せる手段が用意できるまでは出さない
（[DESIGN.md](DESIGN.md) §4.2）。

編集の保存先はアプリのサンドボックスコンテナ内で、中身は人が読める TSV:

```
~/Library/Containers/dev.vimeu.inputmethod.VimeuIME/Data/Library/Application Support/VimeuIME/
  user_word.tsv
  user_collocation.tsv
```

バックアップも端末間の持ち運びも、このディレクトリをコピーするだけでよい。
**辞書を作り直して入れ直しても編集は残る**（`make dict && make install`）。

## 開発

```sh
swift test                      # 単体テスト
make dict                       # Mozc の src/data → vimeu.dic
make verify-dict                # .dic が Mozc の原データと一致することを確認

# 辞書の中身を見る
swift run -c release vimeu-dictbuild inspect dict/vimeu.dic --sample 10

# 1 つの読みを変換して、分割・品詞・コスト内訳を見る
swift run -c release vimeu-eval --dic dict/vimeu.dic --convert きょうはいいてんきですね

# 調整ウィンドウを IME の外で開く（IME 内からはメニュー経由でしか開けないため）
swift run vimeu-preview --reading きょうはいいてんきですね
swift run vimeu-preview --tab connections --dark 1 --snapshot /tmp/tune.png

# 精度回帰
swift run -c release vimeu-eval --dic dict/vimeu.dic --testset corpus/testset.tsv
swift run -c release vimeu-eval --dic dict/vimeu.dic --testset corpus/testset_messenger.tsv
swift run -c release vimeu-eval --dic dict/vimeu.dic --testset corpus/mozc_evaluation.tsv

# ユーザー辞書を効かせて測る（編集がテストセットに与える影響を数字で見る）
swift run -c release vimeu-eval --dic dict/vimeu.dic --testset corpus/testset.tsv \
  --user ~/Library/Containers/dev.vimeu.inputmethod.VimeuIME/Data/Library/Application\ Support/VimeuIME
```

実測値と、それが何に対して検証されているかは [DESIGN.md](DESIGN.md) の §3.6 / §5 にある。

ログは Console.app で `subsystem:dev.vimeu.inputmethod` を絞る。
IME プロセスはブレークポイントで止めるとデスクトップごと固まるため、
ロジックの検証は単体テストと CLI で行うこと。

## ライセンスと出典

辞書データは [google/mozc](https://github.com/google/mozc)（Apache-2.0）の
`src/data/dictionary_oss/` と `src/data/rules/boundary.def` に由来する。
変換コストの計算は Mozc の `src/converter/immutable_converter.cc` を参照して実装した。
本プロジェクトは Google 日本語入力でも Mozc の公式配布物でもない。
