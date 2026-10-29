const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // target/optimize を渡さないと ghostty 側の standardTargetOptions が
    // ホスト向けの既定値になり、クロスコンパイル時に simdutf/highway の
    // 静的ライブラリだけホスト向けに作られてリンクに失敗する。
    //
    // APC で届く kitty graphics と glyph protocol は描画しないので、
    // ghostty-vt 側で無効にして読み捨てさせる。有効のままだと送られた
    // 画像やグリフが Terminal に溜まる。
    //
    // xcframework は使わないので作らせない。既定のままだと macOS ホストで
    // iOS 向けのグラフまで組まれ、Xcode の無い Nix サンドボックスでは
    // iOS SDK が見つからずビルドグラフの構築で失敗する。
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"vt-features" = "-kitty-graphics,-glyph-protocol",
        .@"emit-xcframework" = false,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        mod.addImport("ghostty-terminfo", terminfoModule(b, dep));
        installTerminfo(b, dep);

        const options = b.addOptions();
        options.addOption([]const u8, "ghostty_version", ghosttyVersion(b, dep));
        mod.addOptions("build_options", options);
    }

    const lib = b.addLibrary(.{
        .name = "spectreshell",
        .root_module = mod,
        .linkage = .dynamic,
    });
    b.installArtifact(lib);

    // Elisp files ride along in the same install prefix as the module and
    // terminfo database (share/emacs/site-lisp is the conventional nix/
    // distro location Emacs's own `site-lisp' loading already knows to
    // look at), so that `nix build`'s output alone is a complete,
    // self-contained package (docs/implementation-plan.org Phase 6).
    b.installFile("spectreshell.el", "share/emacs/site-lisp/spectreshell.el");
    b.installFile("spectreshell-eshell.el", "share/emacs/site-lisp/spectreshell-eshell.el");

    installInfoManual(b);

    // The built .so statically links third-party code, so redistributing
    // the build output requires shipping these notices with it
    // (THIRD-PARTY-NOTICES.org); installing them into the output itself
    // means no packaging step can forget them.
    b.installFile("LICENSE", "share/doc/spectreshell/LICENSE");
    b.installFile("THIRD-PARTY-NOTICES.org", "share/doc/spectreshell/THIRD-PARTY-NOTICES.org");

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

/// ghostty の build.zig.zon の版。ghostty は依存として組まれると git を
/// 見ずにこの版を名乗る (src/build/Config.zig) ので、XTVERSION の応答を
/// 同じ ghostty を組み込んだ Ghostty アプリと揃えられる。
fn ghosttyVersion(b: *std.Build, ghostty_dep: *std.Build.Dependency) []const u8 {
    const root = ghostty_dep.builder.root;
    const zon_path = root.join(b.allocator, "build.zig.zon") catch @panic("OOM");
    const source = zon_path.root_dir.handle.readFileAllocOptions(
        b.graph.io,
        zon_path.sub_path,
        b.allocator,
        .limited(1024 * 1024),
        .of(u8),
        0,
    ) catch |err| std.debug.panic("unable to read ghostty's build.zig.zon: {s}", .{@errorName(err)});
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const zon = std.zon.parse.fromSlice(struct { version: []const u8 }, .{
        .gpa = b.allocator,
        .arena = b.allocator,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| std.debug.panic("unable to parse ghostty's build.zig.zon: {s}", .{@errorName(err)});
    return zon.version;
}

/// docs/spectreshell.texi から Info マニュアルを生成して share/info に
/// install する。org ソース (docs/spectreshell.org) から直接生成しない
/// のは、ビルド時依存に Emacs を持ち込まないため (.texi は `just info`
/// で再生成してコミットする運用)。
fn installInfoManual(b: *std.Build) void {
    const makeinfo = b.addSystemCommand(&.{ "makeinfo", "--no-split", "-o" });
    const info_file = makeinfo.addOutputFileArg("spectreshell.info");
    makeinfo.addFileArg(b.path("docs/spectreshell.texi"));

    const install_info = b.addInstallFile(info_file, "share/info/spectreshell.info");
    b.getInstallStep().dependOn(&install_info.step);
}

/// ghostty 本体の `src/terminfo/main.zig` (std のみに依存する自己完結
/// モジュール) が持つ `xterm-ghostty` の terminfo 定義から
/// `share/terminfo` データベースを生成し、既定の install step にぶら
/// 下げる。ghostty 自身の src/build/GhosttyResources.zig の terminfo
/// セクションと同じやり方 (生成 exe の標準出力を `tic -x -o` に渡す)
/// だが、xterm-ghostty 用の1エントリだけで十分なので termcap 変換等は
/// 持ち込まない。
fn installTerminfo(b: *std.Build, ghostty_dep: *std.Build.Dependency) void {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/terminfo_gen.zig"),
        .target = b.graph.host,
    });
    gen_mod.addImport("ghostty-terminfo", terminfoModule(b, ghostty_dep));

    const gen_exe = b.addExecutable(.{
        .name = "spectreshell-terminfo-gen",
        .root_module = gen_mod,
    });

    const run_gen = b.addRunArtifact(gen_exe);
    const terminfo_source = run_gen.captureStdOut(.{});

    const tic = b.addSystemCommand(&.{ "tic", "-x", "-o" });
    const terminfo_dir = tic.addOutputFileArg("terminfo");
    tic.addFileArg(terminfo_source);

    const install_exe = b.addExecutable(.{
        .name = "spectreshell-terminfo-install",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/terminfo_install.zig"),
            .target = b.graph.host,
        }),
    });
    const install = b.addRunArtifact(install_exe);
    install.addDirectoryArg(terminfo_dir);
    install.addDirectoryArg(.{ .relative = .{ .base = .install_prefix, .sub_path = "share/terminfo" } });
    // 引数のパスしかキャッシュの鍵にならず、install 先が消えても再実行
    // されないので、毎回複製する。
    install.has_side_effects = true;
    b.getInstallStep().dependOn(&install.step);
}

/// ghostty の `src/terminfo` (std のみに依存し、ディレクトリ内で閉じた
/// 3 ファイル) を module 化する。dep のパスを直接 root にせず一旦コピー
/// するのは、`ghostty-vt` モジュールが input/function_keys.zig 経由で
/// termio.zig を、その先で同じ `src/terminfo/main.zig` を取り込んでおり、
/// 元パスのままでは 1 つのコンパイル内で同じファイルが 2 つのモジュール
/// に属する (zig が拒否する) ため。
fn terminfoModule(b: *std.Build, ghostty_dep: *std.Build.Dependency) *std.Build.Module {
    const copy = b.addWriteFiles();
    const dir = copy.addCopyDirectory(ghostty_dep.path("src/terminfo"), "", .{});
    return b.createModule(.{ .root_source_file = dir.path(b, "main.zig") });
}
