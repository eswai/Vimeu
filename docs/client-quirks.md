# アプリ別の IMK 挙動と対処（ノウハウ集）

macOS の IME は、アプリ（IMK クライアント）ごとに `setMarkedText` / `insertText` / `selectedRange` などの
扱いが違う。ここには vimeu で実際に問題になった挙動、その原因、対処、確かめた方法をまとめる。
設計の正本は [DESIGN.md](../DESIGN.md)（§4.1 の確定直後の Backspace 再変換）で、本書はその背景と調べ方を書く。

数値と結果には、確かめた日付と対象を書く。「未確認」は試していないことを表す。

## 一覧

| クライアント | 判定 | 再変換の方式 | 確定の方式 | 状態 |
|---|---|---|---|---|
| ネイティブ（メモ、Safari など AppKit / WebKit） | 下記以外すべて | 確定範囲を置換範囲にして `setMarkedText` | marked text の上に `insertText` | 削除方式はメモ・Safari で動作（2026-10-24）。この方式での再変換は未確認 |
| Chromium 系（Chrome などのブラウザ、Claude desktop などの Electron アプリ） | バンドル ID の前方一致（`CommitUndo.chromiumBundlePrefixes`） | Backspace はアプリへ通し、20 ms 後に残りを置換範囲にして `setMarkedText` | 同上 | Claude desktop の入力欄で動作（2026-10-24）。Chrome などほかのアプリは未確認 |
| Firefox | ネイティブと同じ | ネイティブと同じ | 同上（この方式に変えたのは Firefox が理由） | Web ページの入力欄で動作（2026-10-24） |
| Ghostty | ネイティブと同じ | ネイティブと同じ | 同上 | 削除方式は動作しなかった（2026-10-24）。原因は未調査 |

「削除方式」は再変換を作る前に試したもので、同じ `setMarkedText(replacementRange:)` で範囲を戻してから空にする。

## 共通の流れ

1. 確定したときに、確定した文字列・読み・左文脈を記録する（`CommitUndo`）。
2. 次のキーが Backspace なら、`selectedRange` でカーソル位置を取り、その直前の文字列を
   `attributedSubstring(from:)`（返らなければ `string(from:actualRange:)`）で読む。確定した文字列と一致したときだけ再変換する。
3. 一致しなければ IME では処理せず、アプリの通常の Backspace にする。

再変換が通常の Backspace になるときは、たいてい 2 で一致しなかった。2 重表示や文字が残るときは、
範囲の判定は合っていて、範囲を未確定に戻す呼び出しをアプリが期待どおり扱っていない。

## Chromium 系（Chrome / Electron）

### 症状

再変換すると、確定した文字が残ったまま未確定の文字列が表示され、同じ文字が 2 回見える（Claude desktop、2026-10-24）。
ログでは範囲の判定は一致していた（`match=true`）。

### 原因

- Chromium は、IME が処理したキーでも keydown をページへ送る（`windows_key_code` を 0xE5 に変えるが、`key` は `Backspace` のまま）。
- keydown 中の `setMarkedText` はすぐには送られず、キー処理の最後に `ImeSetComposition` として送られる。そのため keydown のほうが先にページへ届く。
- ページのエディタ（Claude desktop の入力欄）は、その時点ではまだ変換中ではないので、自分で Backspace を実行する。それが置換範囲付きの変換とぶつかり、確定した文字が残る。

Blink 自体は置換範囲に対応していて、範囲を選択してから変換を始める（`WebInputMethodControllerImpl::SetComposition`）。
問題はキーの届く順番とエディタの処理にある。

### 対処

- Backspace は IME で処理せずアプリへ通す（`handle` が false を返す）。アプリ自身が最後の 1 文字（書記素）を消す。
- 20 ms 後に、残りの確定範囲（`CommitUndo.rangeLeftAfterBackspace`）を置換範囲にして `setMarkedText` を呼び、Converting に入る。
  キーの外なので、Chromium は置換範囲付きの変換をすぐページへ送る。
- 待つ間に次のキーやクライアント切替があれば取りやめる（`pendingReconversion`）。

### 効かなかった方式（2026-10-24、Claude desktop・Chrome）

| 方式 | 結果 |
|---|---|
| keydown 中に置換範囲付きの `setMarkedText` | 確定した文字が残り 2 重表示 |
| keydown 中に空の `insertText(replacementRange:)` で消してから `setMarkedText` | 同上 |
| Backspace をアプリへ通し、20 ms 後に残りを空の `insertText(replacementRange:)` で消す | 1 文字だけ消え、残りが残ったまま未確定の文字列が出た。Chromium は空の `insertText` で範囲を消さない |

### 判定方法の制約

- アプリのバンドルの中（`Contents/Frameworks/Electron Framework.framework` など）を見れば判定できるが、サンドボックス下の IME からは他アプリのバンドルを読めない。
- `validAttributesForMarkedText` は Chromium と WebKit で同じ一覧を返す（Chromium のコメントに WebKit からの写しとある）ので、見分けに使えない。
- そのためバンドル ID の一覧で判定する。一覧にない Electron アプリでは、2 重表示が起きうる。新しく見つかったら `chromiumBundlePrefixes` に足す。

## Firefox

### 症状

再変換にならず、通常の Backspace として 1 文字消える（2026-10-24）。
vimeu のログは `selected={0, 0} ... read=none match=false` だった。カーソル位置が先頭とされ、照合まで進んでいない。

### 原因

当時の vimeu は、`setMarkedText("")` で未確定文字列を空にしてから `insertText` で確定していた。Firefox の `TextInputHandler.mm` では次のようになる。

1. 空の `setMarkedText` は空文字列での確定（`DispatchCompositionCommitEvent("")`）になり、
   Firefox はカーソル位置を「変換開始位置 + 0」と推定して覚える。
2. 続く `insertText` は変換中ではないので、`eContentCommandInsertText` として挿入される。このとき覚えたカーソル位置は更新されない。
3. ページ（コンテンツプロセス）から選択位置の通知（`OnSelectionChange`）が届くのは、次の Backspace のあとだった。

そのため Backspace の時点で `selectedRange` が変換開始位置（ログでは 0）を返していた。

### 対処

確定は、未確定文字列を空にせず、そのまま `insertText` で置き換える（`commitText`、部分確定も同じ）。
Firefox はこれを確定文字列での確定として扱い、カーソル位置を「変換開始位置 + 確定文字数」と正しく推定する。

再変換を作る前の削除方式が Firefox で動作しなかったのも、同じ原因だった可能性がある（未確認）。

## Ghostty

削除方式は動作しなかった（2026-10-24）。再変換は未確認で、原因も調べていない。調べるときは下の手順で `commitUndo` のログを取る。

## 調べ方

### vimeu のログ

判定に使った値と結果は `commitUndo` のログに出る（`app=` バンドル ID、`selected=`、`read=`、`match=`、`restore=` 方式）。
info レベルは保存されないことがあるので、再現する前に流しておく。zsh には組み込みの `log` があるので、`/usr/bin/log` と書く。

```bash
/usr/bin/log stream --level info --predicate 'subsystem == "dev.vimeu.inputmethod"' --style compact
```

直後なら、次のコマンドで残っている分を読める。

```bash
/usr/bin/log show --last 30m --info --predicate 'subsystem == "dev.vimeu.inputmethod"' --style compact
```

### Firefox の IME ログ

再起動せずに取れる。

1. `about:logging` を開き、モジュールに `IMEHandler:5` を設定する。
2. 出力先をファイルにして記録を始め、再現してから止める。
3. ファイルは `$TMPDIR/log.txt-main.<pid>.moz_log` のような名前で出る。

`SetMarkedText` / `InsertText` / `SelectedRange` / `OnSelectionChange` / `DispatchCompositionCommitEvent` を grep すると、
IME の呼び出しと Firefox が覚えている選択位置の移り変わりが追える。

### 読んだソース

| 対象 | ファイル | 見る関数 |
|---|---|---|
| Chromium（Cocoa 側） | `content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm` | `setMarkedText:selectedRange:replacementRange:`、`insertText:replacementRange:`、`keyEvent:` |
| Chromium（Blink 側） | `third_party/blink/renderer/core/exported/web_input_method_controller_impl.cc`、`core/editing/ime/input_method_controller.cc` | `SetComposition`、`CommitText`、`ReplaceTextAndKeepSelection` |
| Firefox | `widget/cocoa/TextInputHandler.mm` | `IMEInputHandler::SelectedRange`、`DispatchCompositionCommitEvent`、`InsertTextAsCommittingComposition`、`TextInputHandler::InsertText` |

Chromium は `https://chromium.googlesource.com/chromium/src/+/refs/heads/main/<path>?format=TEXT`（base64）、
Firefox は `https://raw.githubusercontent.com/mozilla-firefox/firefox/main/<path>` から取れる。

## 新しいアプリで不具合が出たとき

1. `commitUndo` のログを流して再現し、`match=` を見る。
   - `false`: カーソル位置か文字列の読み取りが合っていない。`selected=` と `read=` で、どちらが原因かを見る。確定のしかたがアプリの推定とずれていないか疑う（Firefox の例）。
   - `true` なのに表示がおかしい: 範囲を戻す呼び出しの扱いの問題。キーの届く順番（Chromium の例）や、置換範囲を無視していないかを見る。
2. アプリ側のログやソースで、IME の呼び出しがどう処理されたかを確かめる。
3. 対処したら、本書の一覧と該当する節、DESIGN.md の §4.1 を更新する。確かめた日付と対象を書く。
