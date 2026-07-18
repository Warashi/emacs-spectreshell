{
  lib,
  stdenv,
  zig,
  ncurses,
  texinfo,
  callPackage,
  runCommand,
  writeShellScriptBin,
  symlinkJoin,
  emacs31-nox,
}:
let
  # macOS の Nix サンドボックスには Xcode がないが、ghostty の
  # pkg/apple-sdk (zlib/simdutf/highway 等の pkg/* がビルドグラフ構築時に
  # 呼ぶ) は zig の LibCInstallation.findNative 経由で
  # `xcode-select --print-path` と `xcrun --sdk <名前> --show-sdk-path` を
  # 実行して SDK を探すため、そのままでは DarwinSdkNotFound で panic する。
  # xcbuild (xcode-select / xcrun 同梱) では解決できない: macosx は darwin
  # stdenv の apple-sdk から解決できるものの、ghostty の build.zig は
  # darwin ターゲットだと XCFramework 用に iOS / iOS Simulator 向けの
  # グラフも無条件に構築し、そこで要求される iphoneos SDK は CLT 由来の
  # Nix apple-sdk には存在しないため。
  # そこで --sdk の値を無視して $SDKROOT (apple-sdk setup hook が設定する
  # macOS SDK) を返すシムで両コマンドを置き換える。zig 側が見るのは
  # 「exit 0 かつ stdout 非空」と SDK パスだけで、iOS 向けステップは
  # グラフに乗るだけで実行されない (このパッケージの install が依存
  # しない) ので、macOS SDK のパスを返しても実害はない。
  # 想定外の引数はエラーにして誤用を検知する。
  xcodeShim = symlinkJoin {
    name = "xcode-shim";
    paths = [
      (writeShellScriptBin "xcode-select" ''
        [ -n "''${SDKROOT:-}" ] || {
          echo "xcode-select shim: SDKROOT is not set" >&2
          exit 1
        }
        echo "$SDKROOT"
      '')
      (writeShellScriptBin "xcrun" ''
        [ -n "''${SDKROOT:-}" ] || {
          echo "xcrun shim: SDKROOT is not set" >&2
          exit 1
        }
        case " $* " in
          *" --show-sdk-path "*) echo "$SDKROOT" ;;
          *)
            echo "xcrun shim: unsupported invocation: xcrun $*" >&2
            exit 1
            ;;
        esac
      '')
    ];
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "emacs-spectreshell";
  # build.zig.zon の .version と spectreshell.el の Version ヘッダに合わせる。
  version = "0.0.1";

  src = ../.;

  # ncurses は build.zig の terminfo install step が呼ぶ `tic` のために、
  # texinfo は Info マニュアル生成 step が呼ぶ `makeinfo` のために要る
  # (docs/design.org の「TERM=xterm-ghostty + terminfo 同梱」)。
  nativeBuildInputs = [
    zig
    ncurses
    texinfo
  ]
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ xcodeShim ];

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
  ''
  # darwin stdenv の apple-sdk は xcbuild 製 xcrun を propagate しており
  # PATH 上でシムより先に来る可能性があるため、シムを先頭に固定する
  + lib.optionalString stdenv.hostPlatform.isDarwin ''
    export PATH="${xcodeShim}/bin:$PATH"
  '';

  nativeCheckInputs = [ emacs31-nox ];

  # Zig のユニットテストと ERT (module 境界 / 描画 / キー入力 / eshell
  # 統合) をパッケージビルドの一部として走らせる。ERT のテストヘルパーは
  # リポジトリルートの zig-out/lib からモジュールを探すため、install 用の
  # ビルドとは別に既定 prefix (zig-out) へのビルドも行う。zig.hook の
  # 既定フラグ ($zigDefaultCpuFlag / $zigDefaultOptimizeFlag) を明示的に
  # 渡すのは、素の `zig build` だと buildPhase (--release=safe
  # -Dcpu=baseline) とは別構成の Debug ビルドを丸ごと再コンパイルした
  # 上に、出荷物と違う成果物を ERT がロードしてしまうため (フラグが
  # 一致していればキャッシュ済みでコンパイルは再実行されない)。eshell
  # 統合テストは PTY 上で子プロセスを spawn するので HOME を用意しておく。
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    zig build test $zigDefaultCpuFlag $zigDefaultOptimizeFlag
    zig build $zigDefaultCpuFlag $zigDefaultOptimizeFlag
    HOME="$TMPDIR" emacs -Q --batch -L . -L test \
      -l test/spectreshell-module-test.el \
      -l test/spectreshell-test.el \
      -l test/spectreshell-key-test.el \
      -l test/spectreshell-eshell-test.el \
      -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';
})
