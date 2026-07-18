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

  # --system は使わない: zig 0.15/0.16 には、--system で渡したパッケージが
  # パス依存 (ghostty の pkg/*) を含むと zig build が無限ループするバグがあるため、
  # グローバルキャッシュの p/ に依存を事前配置する方式で回避する
  postConfigure = ''
    ln -s ${finalAttrs.deps} "$ZIG_GLOBAL_CACHE_DIR/p"
  '';

  # スタブの build.zig はまだ何も install しないため、$out が作られず
  # ビルドが失敗する。成果物を install するようになったら削除してよい
  postInstall = ''
    mkdir -p $out
  '';
})
