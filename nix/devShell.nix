{
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
  just,
  nixfmt,
  ncurses,
  texinfo,
  perl,
  less,
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
    # ERT が POSIX::setsid で制御端末を持たない子を作るのに要る
    # (issues.org の L-23)。
    perl
    # ERT の visual command (em-term.el 迂回) のテストが起動する。
    less
  ];
}
