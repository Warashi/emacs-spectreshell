{
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
  just,
  nixfmt,
  ncurses,
  texinfo,
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
    # `makeinfo`。build.zig の Info マニュアル生成 step が要る。
    texinfo
  ];
}
