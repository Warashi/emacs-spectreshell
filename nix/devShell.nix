{
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
  just,
  nixfmt,
}:
mkShell {
  name = "emacs-spectreshell";
  packages = [
    zig
    zon2nix
    emacs31-nox
    just
    nixfmt
  ];
}
