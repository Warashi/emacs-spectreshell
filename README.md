# emacs-spectreshell

eshell 向けの端末エミュレーション統合。[ghostty](https://ghostty.org/) の
端末エミュレーションライブラリ `ghostty-vt` を Zig 製の Emacs
ダイナミックモジュールから使い、`ls --color`・進捗表示・`less`/`vim`
のような alternate screen アプリの出力を eshell バッファ内で正しく
描画する。

## 概要

- **やること**: eshell で外部プロセスを実行したとき、色・カーソル移動・
  プログレスバー・alternate screen を含む出力を eshell バッファ内に
  正しく描画する。マウス操作 (SGR mouse mode) や OSC 8 ハイパーリンクも
  対応する。
- **やらないこと**: eshell 統合専用であり、`M-x eat` のような汎用の
  スタンドアロン端末エミュレータは提供しない (描画エンジン自体は
  eshell 非依存に作られているため、将来の拡張余地はある)。
- **[eat-eshell-mode](https://codeberg.org/akib/emacs-eat) との関係**:
  「eshell の外部プロセス出力をすべて端末エミュレーション経由にする」
  というアプローチは eat-eshell-mode と同じだが、バックエンドが独自実装
  ではなく ghostty 本体の VT パーサ・状態機械 (`ghostty-vt`) である点が
  異なる。PTY と子プロセスは (eat 同様) Emacs 側が所有し、モジュールは
  バイト列を受け取って更新差分を返すだけの純粋な状態機械になっている。

設計の詳細は [docs/design.md](docs/design.md)、実装フェーズの経緯は
[docs/implementation-plan.md](docs/implementation-plan.md)、モジュール
境界の API 仕様は [docs/module-api.md](docs/module-api.md) を参照。

## 必要環境

- **Emacs 31 以降** (それより前のバージョンへの互換コードは書いていない)
- ビルドには **Zig 0.15.2** 系と、terminfo データベース生成用の
  `tic` (ncurses) が必要
- **nix** (flake) でのビルド・利用を推奨。手動での `zig build` にも対応

## インストール

### nix flake から (推奨)

```elisp
;; ~/.config/emacs/init.el 等
(use-package spectreshell-eshell
  :load-path "/path/to/nix/build/result/share/emacs/site-lisp"
  :demand t
  :config (spectreshell-eshell-mode 1))
```

`nix build github:Warashi/emacs-spectreshell` (このリポジトリを
checkout 済みなら単に `nix build`) で `result/` 以下に

```
result/lib/libspectreshell.so           ; Emacs ダイナミックモジュール
result/share/emacs/site-lisp/*.el       ; spectreshell.el / spectreshell-eshell.el
result/share/terminfo/                  ; xterm-ghostty の terminfo データベース
```

が生成される。`spectreshell.el` は `require` された時点で
`libspectreshell.so` を、`spectreshell-eshell.el` は同梱の terminfo
データベースを、いずれも自分がロードされた場所からの相対パスで自動検出
するので、`load-path` に `result/share/emacs/site-lisp` を通すだけで
このレイアウトのまま動く (手動での `module-load` や `TERMINFO` の設定
は不要)。

nix flake の devShell (`nix develop`) には Zig・ncurses・emacs
(バッチテスト用) 一式が入っている。

### 手動で `zig build`

```sh
git clone https://github.com/Warashi/emacs-spectreshell
cd emacs-spectreshell
zig build            # zig-out/lib/libspectreshell.so, zig-out/share/... を生成
```

`zig-out/lib/libspectreshell.so` と `zig-out/share/terminfo` がリポジトリ
ルートの `spectreshell.el` から見て決め打ちの相対位置にできるため、
`load-path` にリポジトリのルートディレクトリを追加するだけで
nix ビルドと同様に自動検出される:

```elisp
(add-to-list 'load-path "/path/to/emacs-spectreshell")
(use-package spectreshell-eshell
  :demand t
  :config (spectreshell-eshell-mode 1))
```

`zig build` には `tic` (ncurses) が必要。`just build` / `just test` /
`just test-el` / `just load-check` / `just nix-check` に開発時によく使う
コマンドをまとめてある ([Justfile](Justfile) 参照)。

## 設定例

```elisp
(use-package spectreshell-eshell
  ;; nix ビルドの場合は :load-path で result/share/emacs/site-lisp を、
  ;; 手動 zig build の場合はリポジトリルートを指定する。
  :load-path "/path/to/site-lisp-or-repo-root"
  :demand t
  :custom
  ;; どちらも既定値のままで自動検出・自動フォールバックが効く
  ;; (docstring 参照)。ここでは明示指定の例として書いているだけで、
  ;; 通常はこの :custom ブロック自体不要。
  (spectreshell-term-name "xterm-ghostty")
  (spectreshell-terminfo-directory nil)
  :config
  (spectreshell-eshell-mode 1))
```

`spectreshell-eshell-mode` はグローバルマイナーモードなので、一度有効に
すれば以後すべての eshell バッファの外部プロセス実行に適用される
(バッファごとに有効化する必要はない)。無効化 (`(spectreshell-eshell-mode
-1)`) すれば eshell は通常の (端末エミュレーションなしの) 動作に戻る。

## 機能一覧

- SGR 全般 (16色 / 256色 / 24bit)、カーソル制御、スクロール領域、
  alternate screen (`less`・`vim` 等)、bracketed paste、タイトル変更
  (OSC 0/2)
- マウス (SGR mouse mode): クリック・ドラッグ・ホイールスクロールを
  端末座標に変換して送信。マウストラッキングを使わないコマンドの実行中は
  通常の Emacs マウス操作 (`mouse-set-point`/ホイールスクロール) に
  フォールバックする
- OSC 8 ハイパーリンク (クリック可能な button として描画)
- `xterm-ghostty` の terminfo をビルド時生成・同梱し、`TERM`/`TERMINFO`
  として子プロセスに自動注入 (未検出時は `xterm-256color` に自動
  フォールバック)
- スクロールバックは Emacs バッファへ確定化するので、isearch・コピー・
  `eshell-previous-prompt` などの Emacs の機能がそのまま効く
- semi-char モード (実行中プロセスへほぼ全キーを送信) と emacs モード
  (通常のバッファ編集) の切り替え (`C-c C-e` / `C-c C-j`)

## 既知の制限

- **char モード非対応**: `C-c` を含む全キー送信は v1 のスコープ外
  (`C-c` は Emacs のプレフィックスキーとして残る)
- **実行中プロセスへの IME 直接入力は対象外**: ddskk 等での日本語入力は
  eshell のコマンドライン編集中 (プロセス非実行時) は無条件で動くが、
  実行中のプロセスへ直接入力する経路はない。`C-y` (kill-ring からの
  bracketed paste) 経由での日本語送信は可能
- **OSC 52 クリップボード・画像 (kitty graphics/sixel) は未実装**
- **TRAMP / リモート `default-directory` は対象外**: リモートでは常に
  eshell 本来の (非端末) 経路にフォールバックする
- **パイプラインは末尾のプロセスのみ端末に接続**: `cmd1 | cmd2` の
  `cmd1` の出力は spectreshell を経由しない
- Emacs が新規に開く pty は既定で `-echo -onlcr` になっており、素の LF
  だけの出力が階段状にずれてしまうため `stty ... sane` 経由で回避して
  いる。`/bin/sh` と `stty` が存在しない環境 (通常の Unix 系ではまず
  問題にならない) では機能しない

詳細な手動確認手順は [docs/manual-testing.md](docs/manual-testing.md)
を参照。

## ライセンス

MIT License。詳細は [LICENSE](LICENSE) を参照。
