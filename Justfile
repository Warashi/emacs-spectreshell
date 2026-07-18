build:
  zig build

test:
  zig build test

# ビルドした so が手元の Emacs で module-load できることを確認する
load-check: build
  emacs -Q --batch --eval '(progn (module-load (expand-file-name "zig-out/lib/libspectreshell.so")) (message "module-load OK"))'

# emacs-module 境界 (spectreshell--create/--feed/... ) の ERT スモークテスト
test-el: build
  emacs -Q --batch -L test -l test/spectreshell-module-test.el -f ert-run-tests-batch-and-exit

zon2nix:
  zon2nix --15 --nix=build.zig.zon.nix build.zig.zon
  nixfmt build.zig.zon.nix
