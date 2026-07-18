# 手動確認手順

Phase 5 (`spectreshell-eshell-mode`) の ERT ではカバーしきれない、
実際に画面を見ないと確認できない項目の手順と、現状の既知の制限を記録する。
自動テストは `test/spectreshell-eshell-test.el` (`just test-el`) を参照。

## 準備

```elisp
(add-to-list 'load-path "/path/to/emacs-spectreshell")
(module-load "/path/to/emacs-spectreshell/zig-out/lib/libspectreshell.so")
(require 'spectreshell-eshell)
(spectreshell-eshell-mode 1)
(eshell)
```

## 確認項目

### `ls --color`

`ls -la --color=always` (または `ls -la` 相当の色付き `ls`) を実行し、
ファイル種別ごとの色分けが SGR エスケープの生バイトではなく実際の色
(face) として表示されること、桁揃えが崩れていないことを確認する。

### 進捗表示するコマンド

`\r` で同じ行を上書きするコマンド (`rsync --progress`、`curl` の進捗
バー、あるいは手元で `printf 'progress: %d%%\r' 10; sleep 0.3; printf
'progress: %d%%\r' 50; sleep 0.3; printf 'progress: %d%%\n' 100' 相当
を実行) を試し、行が積み重ならず同じ行が上書きされていくことを確認する。

### `less`

`less` で複数ページのファイル (このリポジトリの `docs/design.md` 等)
を開き、alternate screen に切り替わること (元のプロンプト行が一時的に
隠れる)、`j`/`k`/矢印キーでのスクロールが効くこと、`q` で終了すると
alternate screen が消えて元のプロンプト位置に戻ることを確認する。

`less` は eshell 標準の `eshell-visual-commands` に含まれており、
`spectreshell-eshell-mode` なしでは `em-term.el` が別の `term-mode`
バッファへ実行を逃がしてしまう (spectreshell が一切関与できなくなる)。
`spectreshell-eshell-mode` は `eshell-visual-command-p` にも advice して
この迂回を無効化し、eshell バッファ内でそのまま spectreshell 経由で
描画されるようにしている
(`test/spectreshell-eshell-test.el` の
`spectreshell-eshell-test-visual-command-stays-in-eshell-buffer` 参照)。

### `vim`

`vim` である程度編集操作 (文字入力・カーソル移動・保存) を行い、
alternate screen 内でのカーソル移動・色・ステータスラインが正しく
描画されること、`:q` で抜けると元の eshell バッファに戻ることを確認する。

### マウス操作

`less` や `vim` のようにマウストラッキングを有効化するアプリを
alternate screen で実行し、クリックでのカーソル移動・ドラッグでの
範囲選択 (vim のビジュアルモード等)・ホイールスクロールが効くことを
確認する。マウストラッキングを有効化しないコマンド (プレーンな
`ls` 等) の実行中は、通常どおりクリックで point が動き、ホイールで
バッファがスクロールすることも確認する
(`spectreshell-mouse-down`/`spectreshell-mouse-wheel` の
`mouse-set-point`/`mwheel-scroll` フォールバック)。

### eshell コマンドライン編集での ddskk

ddskk 有効化 (`skk-mode`) した状態で、プロセスを実行していない
eshell のコマンドライン (プロンプトの後ろ) で日本語入力を行い、
▽/▼ の変換過程を含めて通常の Emacs バッファ編集と同様に動作すること
を確認する (design.md の方針どおり、プロセス実行中は対象外)。

## 既知の制限

- **TRAMP / リモート `default-directory` は対象外。**
  `spectreshell-eshell--gather-process-output-advice` は
  `file-remote-p` を検出すると spectreshell への接続を行わず、常に
  eshell 本来の (非端末) 経路にフォールバックする。
- **パイプラインは末尾のプロセスのみ端末に接続する。**
  `cmd1 | cmd2` の `cmd1` の出力は spectreshell を経由しない
  (docs/design.md の割り切り)。
- **プロセス実行中への IME 直接入力は対象外** (design.md 参照)。
  `C-y` (kill-ring からの bracketed paste) 経由での日本語送信は可能。
- **OSC 52 クリップボード・画像 (kitty graphics/sixel) は未実装**
  (Phase 6 の将来拡張)。
- Emacs が新規に開く pty は既定で `-echo -onlcr` (`stty -a` で確認可能)
  になっており、素の LF だけの出力が階段状にずれてしまう。
  `spectreshell-eshell--wrap-command-for-pty' が `term.el` と同じ
  `/bin/sh -c "stty ... sane; exec ..."` 経由で回避しているため、
  `/bin/sh` と `stty` が `PATH`/`/bin` に存在しない環境
  (通常の Unix 系ではまず問題にならない) では機能しない。
