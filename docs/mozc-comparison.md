# vimeu と Mozc の機能比較

設計の正本は [DESIGN.md](../DESIGN.md)。本書はその時点の差異の一覧である。

- Mozc 側: `google/mozc` コミット `76887c679`（v3.34、2026-06-24）の `src/` を読んで確認した
- vimeu 側: コミット `6247431` 時点の DESIGN.md と `Sources/` を読んで確認した
- 記号: ○＝あり、△＝一部あり、✗＝なし

## 変換エンジン

| 機能 | Mozc | vimeu | 補足 |
|---|---|---|---|
| 辞書（`dictionary_oss`） | ○ | ○ | vimeu は `src/data` のテキストから自前の mmap 形式に変換。読みにかな以外を含む行と 17 かな以上の行は落とす（DESIGN.md §2.1） |
| 単語コスト＋接続コストの Viterbi | ○ | ○ | 式は同じ。`boundary.def` の prefix/suffix ペナルティも同じ |
| n-best | ○（`NBestGenerator`） | ○（A*、厳密な k-best） | vimeu には `structure_cost` と `CandidateFilter` がない |
| 文節（`Segmenter`） | ○ | ✗ | vimeu は文全体の候補だけを出す |
| 文節の伸縮・移動 | ○（`SegmentWidthExpand/Shrink`、`SegmentFocus*`） | ✗ | |
| 打ち間違いの補正（`KeyCorrector`、`use_typing_correction`） | ○ | ✗ | |
| suffix 辞書・単漢字辞書 | ○（`suffix_dictionary`、`single_kanji_dictionary`） | ✗ | |
| 数字と接尾語の再分割など | ○ | ✗ | |
| 履歴をラティスに載せる（history segment） | ○ | △ | vimeu は部分確定の直後だけ、直前の語の rid を引き継ぐ（DESIGN.md §4.1） |
| 予測・サジェスト（`prediction/`、realtime conversion） | ○ | ✗ | |
| 学習（`user_history_predictor`、`user_segment_history_rewriter`、`user_boundary_history_rewriter`） | ○ | ✗ | 設計上入れていない |
| 共起 | △（`CollocationRewriter`。OSS の `collocation.txt` は 40 行） | ○ | vimeu はユーザーが手で登録する。正のペアは −3453 の再ランク、負のペアは除外（DESIGN.md §3.5） |
| PMI | ✗ | ✗ | |

## rewriter

Mozc の `rewriter/rewriter.cc` に登録されているもの。vimeu はどれも持っていない。

| 系統 | Mozc の rewriter |
|---|---|
| 文字種・表記 | Transliteration, T13nPromotion, Variants（全角・半角）, EnglishVariants, LanguageAware, SmallLetter, IvsVariants |
| 数・日付・計算 | Number（漢数字など）, Date, Calculator, Zipcode, Unicode |
| 記号・絵文字 | Symbol, Emoticon, Emoji |
| 単漢字・用例 | SingleKanji, Usage, Correction（読みの誤り） |
| 候補の整理 | FocusCandidate, EnvironmentalFilter, RemoveRedundantCandidate, A11yDescription |
| 学習 | UserBoundaryHistory, UserSegmentHistory |
| その他 | UserDictionary, Dice, Fortune, Command, Version |

vimeu が代わりに持っているのは次の 2 つだけで、どちらも辞書のコスト計算には影響しない表示上の選択肢である。

- Control+J / K：ひらがな・カタカナにする
- 数字：候補ごとに全角の表記を加える（DESIGN.md §4.1）

## ユーザー辞書

| 機能 | Mozc | vimeu |
|---|---|---|
| 語の追加 | ○（`user_pos.def` の品詞を選び、活用形にも展開する） | ○（名詞,サ変接続 に固定。活用形には展開しない） |
| 追加語のコスト | 固定値 | 自分で指定する（初期値 1000） |
| システム辞書の語のコストを変える | ✗ | ○（強める / 弱める ∓500、数値を直接入力） |
| システム辞書の語を消す | △（予測候補を消す `DeleteSelectedCandidate` だけ） | ○（無効化・復活） |
| 接続コストを変える | ✗ | ○（品詞名で保存する） |
| 辞書を複数持つ | ○（`kMaxDictionarySize = 100`） | ✗（TSV 3 ファイル） |
| 他の IME からの取り込み | ○（MS-IME / ATOK / ことえり / Gboard、`user_dictionary_importer.h`） | ✗ |
| 候補がなぜ勝ったかの表示 | ✗ | ○（調整ウィンドウで単語・接続・共起の内訳を出す） |

## 入力と UI（macOS）

| 機能 | Mozc | vimeu |
|---|---|---|
| ローマ字入力 | ○（変換表を編集できる、`custom_roman_table`） | ○（固定） |
| かな入力 | ○ | ✗ |
| 入力モード | ひらがな・カタカナ・半角カナ・英数など（`mac/Info.plist`） | 日本語のみ（英字は ABC 入力ソースで打つ） |
| キーマップ | ○（MS-IME / ATOK / ことえり / カスタム、`data/keymap/`） | ✗（固定） |
| 句読点・記号のスタイル、全角・半角の規則 | ○（`punctuation_method`、`symbol_method`、`character_form_rules`） | ✗（`,` `.` `/` `-` を 、。・ー に固定） |
| ライブ変換 | ✗（予測の realtime conversion とは別物） | ○ |
| 自動変換 | △（句読点のキーで変換する `use_auto_conversion`） | ○（入力が止まってから時間で確定） |
| 長い入力の部分確定 | △（先頭の文節だけ確定する `CommitOnlyFirstSegment`） | ○（文字数・候補の安定・品詞で境界を選ぶ） |
| 確定の取り消し | ○（`Undo`、Ctrl+Backspace） | ○（確定直後の Backspace で再変換） |
| 選択した文字列の再変換 | ○（`Reconvert`、`selectedRange` を使う） | ✗ |
| シークレットモード | ○（`incognito_mode`） | 不要（学習しないため） |
| プロセス構成 | Converter・Renderer・Qt の GUI に分かれている | Swift の単一プロセス、mmap 辞書 |

## 精度

Mozc の `data/dictionary_oss/evaluation.tsv` のうち、Mozc 自身が `OK:` と記録している 429 件
（`corpus/mozc_evaluation.tsv`）で、vimeu の文精度は 91.14%（DESIGN.md §3.6 の実測値）。
DESIGN.md は残りの差を、rewriter・segmenter・学習（vimeu が継承しなかった部分）によるものとしている。
Mozc 自体の精度は本書では測っていない。
