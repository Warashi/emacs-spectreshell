build:
  zig build

test:
  zig build test

# フォーマット・ドキュメント文字列の静的検査一式
lint:
  zig fmt --check build.zig src
  nixfmt --check flake.nix default.nix shell.nix nix/*.nix build.zig.zon.nix
  emacs -Q --batch --eval '(progn (require (quote checkdoc)) (setq checkdoc-diagnostic-buffer "*warn*") (dolist (f (list "spectreshell.el" "spectreshell-eshell.el")) (checkdoc-file f)) (with-current-buffer "*warn*" (when (re-search-backward "^[^*[:space:]].*:[0-9]+:" nil t) (princ (buffer-string)) (kill-emacs 1))))'

# コミット前に回す検査一式 (lint + Zig テスト + ERT + module-load 確認)
check: lint test test-el load-check

# ビルドしたモジュール (Linux: .so / darwin: .dylib) が手元の Emacs で
# module-load できることを確認する
load-check: build
  emacs -Q --batch --eval '(let ((path (seq-find (function file-exists-p) (mapcar (function expand-file-name) (list "zig-out/lib/libspectreshell.so" "zig-out/lib/libspectreshell.dylib"))))) (unless path (error "load-check: module not found under zig-out/lib")) (module-load path) (message "module-load OK"))'

# emacs-module 境界と spectreshell.el 描画エンジン・キー入力・eshell 統合の ERT テスト一式
test-el: build
  emacs -Q --batch -L . -L test -l test/spectreshell-module-test.el -l test/spectreshell-test.el -l test/spectreshell-key-test.el -l test/spectreshell-eshell-test.el -f ert-run-tests-batch-and-exit

# Info マニュアルの texi を docs/spectreshell.org から再生成する。
# 生成物の .texi をコミットしておくのは、ビルド (zig build / nix build) が
# Emacs なしで makeinfo だけで .info を作れるようにするため。
# マニュアルを編集したらこのレシピで .texi を更新して一緒にコミットする。
info:
  emacs -Q --batch docs/spectreshell.org --eval '(progn (require (quote ox-texinfo)) (org-texinfo-export-to-texinfo))'

zon2nix:
  zon2nix --15 --nix=build.zig.zon.nix build.zig.zon
  nixfmt build.zig.zon.nix

# nix build の成果物 (so + el + terminfo + Info マニュアル + 許諾表示)
# だけで module-load + start + feed の最小動作をスモークテストする
# (docs/implementation-plan.org Phase 6:
# 「nix build の成果物だけで新規環境にセットアップできる」ことの確認)。
nix-check:
  nix build --out-link result
  test -f result/share/info/spectreshell.info
  test -f result/share/doc/spectreshell/LICENSE
  test -f result/share/doc/spectreshell/THIRD-PARTY-NOTICES.org
  emacs -Q --batch -L result/share/emacs/site-lisp --eval '(progn (require (quote spectreshell)) (require (quote spectreshell-eshell)) (with-temp-buffer (let ((term (spectreshell-start (current-buffer) 5 10 (lambda (bytes) bytes)))) (spectreshell-feed term "hello") (unless (string-prefix-p "hello" (buffer-string)) (error "nix-check: unexpected buffer contents: %S" (buffer-string))) (unless spectreshell-terminfo-directory (error "nix-check: terminfo not auto-detected")) (message "nix-check OK"))))'
