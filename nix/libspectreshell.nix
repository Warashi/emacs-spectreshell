{
  lib,
  stdenv,
  zig,
  ncurses,
  texinfo,
  callPackage,
  runCommand,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libspectreshell";
  version = "dev";

  src = ../.;

  # ncurses は build.zig の terminfo install step が呼ぶ `tic` のために、
  # texinfo は Info マニュアル生成 step が呼ぶ `makeinfo` のために要る
  # (docs/design.org の「TERM=xterm-ghostty + terminfo 同梱」)。
  nativeBuildInputs = [
    zig
    ncurses
    texinfo
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
  # symlink ではなく実体コピーにする: ビルド時実行 exe は依存パッケージの
  # ディレクトリを cwd として相対パスで spawn されるため、p/ が store への
  # symlink だと物理 cwd が /nix/store 側になり相対パス解決が壊れる
  postConfigure = ''
    mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"
    cp -rL ${finalAttrs.deps}/. "$ZIG_GLOBAL_CACHE_DIR/p/"
    chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR/p"
  '';
})
