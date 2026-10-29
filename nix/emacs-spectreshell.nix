{
  lib,
  stdenv,
  zig,
  ncurses,
  texinfo,
  perl,
  less,
  darwin,
  callPackage,
  emacs31-nox,
}:
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
  ];

  deps = callPackage ../build.zig.zon.nix {
    name = "${finalAttrs.pname}-cache-${finalAttrs.version}";
  };

  # --system は使わない: zig 0.17.0 は --system で渡したパッケージのパス依存
  # (ghostty の pkg/*) を絶対パスに解決して拒否する (zon2nix の README) ため、
  # zig がソースの横で依存を探す zig-pkg に事前配置する方式で回避する
  # symlink ではなく実体コピーにする: ビルド時実行 exe は依存パッケージの
  # ディレクトリを cwd として相対パスで spawn されるため、zig-pkg が store への
  # symlink だと物理 cwd が /nix/store 側になり相対パス解決が壊れる
  postConfigure = ''
    cp -rL ${finalAttrs.deps} zig-pkg
    chmod -R u+w zig-pkg
  '';

  # perl は checkPhase の ERT が POSIX::setsid で「制御端末を持たない
  # 子」を作って pty ラッパを検査する (docs/issues.org の L-23) ために
  # 要る。util-linux の setsid(1) は darwin に無く、その間 macOS では
  # このテストが skip されていた。less は em-term.el の visual command
  # 迂回のテストが実際に起動する。sandbox には無いので、無ければ skip
  # だった間はどのプラットフォームでも一度も走っていなかった。どちらの
  # ERT も skip せず失敗にするので、依存を落とせば CI が気付く。
  nativeCheckInputs = [
    emacs31-nox
    perl
    less
  ]
  # darwin では Apple の stty (adv_cmds) を PATH の先頭に置く。stdenv の
  # initialPath にある GNU coreutils の stty は sane で c_cc も戻すのに
  # 対し、Apple のものは flag word しか写さない (L-40)。実機の eshell が
  # 解決するのは /bin/stty で、sandbox には無いため、同じソースから
  # ビルドしたものを入れて実機と同じ経路を走らせる。
  ++ lib.optionals stdenv.hostPlatform.isDarwin [ darwin.adv_cmds ];

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
      -l test/spectreshell-key-table-test.el \
      -l test/spectreshell-eshell-test.el \
      -l test/spectreshell-explore-recheck-test.el \
      -l test/spectreshell-explore-input-test.el \
      -l test/spectreshell-explore-lifecycle-test.el \
      -l test/spectreshell-explore-apps-test.el \
      -l test/spectreshell-explore-geometry-test.el \
      -l test/spectreshell-explore-module-test.el \
      -l test/spectreshell-explore-stderr-test.el \
      -f ert-run-tests-batch-and-exit
    runHook postCheck
  '';
})
