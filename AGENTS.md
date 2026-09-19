次の文章を参考にすること

https://github.com/ShikiSuen/ShikiSuen/blob/main/TechNotes/macOS_Input_Method_Development_Guidelines_2026/macOS_Input_Method_Development_Guidelines_2026-ENU.md

実装言語 swift

vimeu は mozc の辞書をそのまま使い、単語コストと接続コストによる変換コストの計算も
mozc と同じにする。
rewriter など付加的な変換ロジックは継承しない。PMI は使わない。
ユーザー辞書によって単語コストの編集と不要な単語の削除ができるようにする。

設計の正本は DESIGN.md。数値を書くときは実測値を書き、何に対して検証したかも書くこと。
