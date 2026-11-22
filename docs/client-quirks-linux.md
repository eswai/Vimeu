# クライアント別の挙動（Linux / fcitx5）

Linux 版（[DESIGN.md](../DESIGN.md) §8）を実際のアプリで確かめた結果をまとめる。
macOS の [client-quirks.md](client-quirks.md) と同じく、結果には確かめた日付と対象を書く。
「未確認」は試していないことを表す。

確定直後の Backspace による再変換は、クライアントが fcitx5 に surrounding text を渡していることが前提になる。
渡していないクライアントでは、Backspace は通常の 1 文字削除になる（設計どおりの動作）。

| クライアント | 接続方式 | 入力・ライブ変換・候補 | 再変換（surrounding text） | 状態 |
|---|---|---|---|---|
| fcitx5 testfrontend | — | 動作（2026-11-22、`testvimeu`） | 動作（2026-11-22、`testvimeu`） | 自動テスト |
| foot | text-input-v3 | 未確認 | 未確認 | |
| Ghostty | text-input-v3 / GTK | 未確認 | 未確認 | |
| Firefox | text-input-v3 / GTK | 未確認 | 未確認 | |
| Chromium / Electron（`--enable-wayland-ime`） | text-input-v1/v3 | 未確認 | 未確認。macOS では 20 ms の遅延が必要だった | |
| GTK4 アプリ | GTK IM モジュール / text-input-v3 | 未確認 | 未確認 | |
| Qt6 アプリ | fcitx5-qt | 未確認 | 未確認 | |

## 調べ方

`make linux-dev-run` で起動した fcitx5 は、デーモンにならずにログを端末に出す。vimeu のログはカテゴリ `vimeu` に出る
（`--verbose=vimeu=5`）。止めるときは Ctrl+C を押し、普段の fcitx5 を `fcitx5 -rd` で起動し直す。
再変換が通常の Backspace になったときは、`--verbose=vimeu=5,default=5` にして、surrounding text が来ているかを見る。

fcitx5 を systemd のユーザーユニットが管理している環境（Omarchy の `omarchy-fcitx5.service` は `Restart=always` で、
D-Bus の自動起動もこのユニットに向いている）では、`make linux-dev-run` で起動した fcitx5 は数秒で置き換えられる
（2026-11-22 に確認）。その場合は `make linux-dev-service` を使う。ユニットに一時的な drop-in
（`$XDG_RUNTIME_DIR` の下に置くので再起動で消える）を足してビルドツリーを読ませ、ユニットを再起動する。
ログは `journalctl --user -u omarchy-fcitx5.service -f` で見る。元に戻すときは `make linux-dev-service-off` を使う。
