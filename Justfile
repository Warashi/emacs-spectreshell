build:
  zig build

test:
  zig build test

# ビルドした so が手元の Emacs で module-load できることを確認する
load-check: build
  emacs -Q --batch --eval '(progn (module-load (expand-file-name "zig-out/lib/libspectreshell.so")) (message "module-load OK"))'

# emacs-module 境界と spectreshell.el 描画エンジン・キー入力・eshell 統合の ERT テスト一式
test-el: build
  emacs -Q --batch -L . -L test -l test/spectreshell-module-test.el -l test/spectreshell-test.el -l test/spectreshell-key-test.el -l test/spectreshell-eshell-test.el -f ert-run-tests-batch-and-exit

zon2nix:
  zon2nix --15 --nix=build.zig.zon.nix build.zig.zon
  nixfmt build.zig.zon.nix

# nix build の成果物 (so + el + terminfo) だけで module-load + start +
# feed の最小動作をスモークテストする (docs/implementation-plan.md Phase 6:
# 「nix build の成果物だけで新規環境にセットアップできる」ことの確認)。
nix-check:
  nix build --out-link result
  emacs -Q --batch -L result/share/emacs/site-lisp --eval '(progn (require (quote spectreshell)) (require (quote spectreshell-eshell)) (with-temp-buffer (let ((term (spectreshell-start (current-buffer) 5 10 (lambda (bytes) bytes)))) (spectreshell-feed term "hello") (unless (string-prefix-p "hello" (buffer-string)) (error "nix-check: unexpected buffer contents: %S" (buffer-string))) (unless spectreshell-terminfo-directory (error "nix-check: terminfo not auto-detected")) (message "nix-check OK"))))'
