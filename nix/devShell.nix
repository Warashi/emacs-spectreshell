{
  mkShell,
  zig,
  zon2nix,
}:
mkShell {
  name = "emacs-spectreshell";
  packages = [
    zig
    zon2nix
  ];
}
