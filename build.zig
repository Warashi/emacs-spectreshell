const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{})) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        installTerminfo(b, dep);
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

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
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
/// 持ち込まない。`cp -R` を使うのは、`tic` が複数名 (xterm-ghostty /
/// ghostty / Ghostty) をシンボリックリンクで表現するため
/// (`std.Build.Step.InstallDir` はシンボリックリンクを保存できない)。
fn installTerminfo(b: *std.Build, ghostty_dep: *std.Build.Dependency) void {
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("src/terminfo_gen.zig"),
        .target = b.graph.host,
    });
    gen_mod.addImport("ghostty-terminfo", b.createModule(.{
        .root_source_file = ghostty_dep.path("src/terminfo/main.zig"),
    }));

    const gen_exe = b.addExecutable(.{
        .name = "spectreshell-terminfo-gen",
        .root_module = gen_mod,
    });

    const run_gen = b.addRunArtifact(gen_exe);
    const terminfo_source = run_gen.captureStdOut();

    const tic = b.addSystemCommand(&.{ "tic", "-x", "-o" });
    const terminfo_dir = tic.addOutputFileArg("terminfo");
    tic.addFileArg(terminfo_source);
    _ = tic.captureStdErr();

    const mkdir = b.addSystemCommand(&.{"mkdir"});
    mkdir.addArgs(&.{"-p"});
    mkdir.addArg(b.fmt("{s}/share", .{b.install_path}));

    const cp = b.addSystemCommand(&.{ "cp", "-R" });
    cp.addFileArg(terminfo_dir);
    cp.addArg(b.fmt("{s}/share", .{b.install_path}));
    cp.step.dependOn(&mkdir.step);

    b.getInstallStep().dependOn(&cp.step);
}
