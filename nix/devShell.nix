{
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
  just,
  nixfmt,
  ncurses,
}:
mkShell {
  name = "emacs-spectreshell";
  packages = [
    zig
    zon2nix
    emacs31-nox
    just
    nixfmt
    # `tic` (terminfo コンパイラ)。build.zig の terminfo install step が要る。
    ncurses
  ];
}
