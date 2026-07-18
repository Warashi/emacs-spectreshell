build:
  zig build

test:
  zig build test

# ビルドした so が手元の Emacs で module-load できることを確認する
load-check: build
  emacs -Q --batch --eval '(progn (module-load (expand-file-name "zig-out/lib/libspectreshell.so")) (message "module-load OK"))'

zon2nix:
  zon2nix --15 --nix=build.zig.zon.nix build.zig.zon
  nixfmt build.zig.zon.nix
