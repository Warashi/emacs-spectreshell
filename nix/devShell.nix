{
  mkShell,
  zig,
  zon2nix,
  emacs31-nox,
}:
mkShell {
  name = "emacs-spectreshell";
  packages = [
    zig
    zon2nix
    emacs31-nox
  ];
}
