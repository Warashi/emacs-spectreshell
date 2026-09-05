{
  lib,
  stdenv,
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
  just,
  nixfmt,
  ncurses,
  texinfo,
  util-linux,
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
  ]
  # `setsid`。ERT が制御端末を持たない子を作るのに要る (issues.org の
  # L-23)。darwin には無いので Linux のみ。
  ++ lib.optionals stdenv.hostPlatform.isLinux [ util-linux ];
}
