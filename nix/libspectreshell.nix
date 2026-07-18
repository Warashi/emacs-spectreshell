{
  lib,
  stdenv,
  zig,
  callPackage,
  runCommand,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libspectreshell";
  version = "dev";

  src = ../.;

  nativeBuildInputs = [
    zig
  ];

  deps = callPackage ../build.zig.zon.nix {
    name = "${finalAttrs.pname}-cache-${finalAttrs.version}";
    # workaround for https://codeberg.org/ziglang/zig/issues/32121
    linkFarm =
      name: entries:
      runCommand name { } ''
        mkdir -p $out
        ${lib.concatMapStringsSep "\n" (e: ''
          cp -rL ${e.path} $out/${e.name}
        '') entries}
      '';
  };

  zigBuildFlags = [
    "--system"
    finalAttrs.deps.out
  ];
})
