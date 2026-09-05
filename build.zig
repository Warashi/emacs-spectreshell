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
    if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        mod.addImport("ghostty-terminfo", terminfoModule(b, dep));
        installTerminfo(b, dep);
    }

    const lib = b.addLibrary(.{
        .name = "spectreshell",
        .root_module = mod,
        .linkage = .dynamic,
        // Debug の既定 (zig 0.15 自前 x86_64 バックエンド) に任せない:
        // 自前バックエンドが生成した .so は Emacs から dlopen して呼ぶと
        // SmpAllocator.getCpuCount 内の未初期化レジスタ参照で segfault
        // する (x86_64 のみ、ReleaseSafe/LLVM では発生しない)。自前
        // バックエンドが shared library でも安定したら外してよい。
        .use_llvm = true,
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
    const terminfo_source = run_gen.captureStdOut();

    const tic = b.addSystemCommand(&.{ "tic", "-x", "-o" });
    const terminfo_dir = tic.addOutputFileArg("terminfo");
    tic.addFileArg(terminfo_source);

    const install = InstallTerminfo.create(b, terminfo_dir, "share/terminfo");
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

/// `tic` が生成した terminfo データベースのディレクトリを install
/// prefix へ複製するステップ。`std.Build.Step.InstallDir` を使わないの
/// は、tic が別名 `ghostty` を `x/xterm-ghostty` へのシンボリックリンク
/// として出力するのに対し、InstallDir の make はディレクトリと通常ファ
/// イル以外のエントリを読み飛ばす (zig 0.15.2) ため、リンクが install
/// されず TERM=ghostty を引けなくなるから。
const InstallTerminfo = struct {
    step: std.Build.Step,
    source_dir: std.Build.LazyPath,
    install_subdir: []const u8,

    fn create(
        b: *std.Build,
        source_dir: std.Build.LazyPath,
        install_subdir: []const u8,
    ) *InstallTerminfo {
        const install = b.allocator.create(InstallTerminfo) catch @panic("OOM");
        install.* = .{
            .step = .init(.{
                .id = .custom,
                .name = b.fmt("install terminfo to {s}", .{install_subdir}),
                .owner = b,
                .makeFn = make,
            }),
            .source_dir = source_dir.dupe(b),
            .install_subdir = b.dupePath(install_subdir),
        };
        source_dir.addStepDependencies(&install.step);
        return install;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const b = step.owner;
        const install: *InstallTerminfo = @fieldParentPtr("step", step);
        step.clearWatchInputs();
        _ = try step.addDirectoryWatchInput(install.source_dir);

        const dest_prefix = b.getInstallPath(.prefix, install.install_subdir);
        const src_dir_path = install.source_dir.getPath3(b, step);
        var src_dir = src_dir_path.root_dir.handle.openDir(
            src_dir_path.subPathOrDot(),
            .{ .iterate = true },
        ) catch |err| {
            return step.fail("unable to open terminfo directory '{f}': {s}", .{
                src_dir_path, @errorName(err),
            });
        };
        defer src_dir.close();

        var all_cached = true;
        var entry_count: usize = 0;
        var it = try src_dir.walk(b.allocator);
        while (try it.next()) |entry| {
            const dest_path = b.pathJoin(&.{ dest_prefix, entry.path });
            switch (entry.kind) {
                .directory => {
                    const prev = try step.installDir(dest_path);
                    all_cached = all_cached and prev == .existed;
                },
                .file => {
                    const src_path = try install.source_dir.join(b.allocator, entry.path);
                    const prev = try step.installFile(src_path, dest_path);
                    all_cached = all_cached and prev == .fresh;
                    entry_count += 1;
                },
                .sym_link => {
                    var buf: [std.fs.max_path_bytes]u8 = undefined;
                    const target = src_dir.readLink(entry.path, &buf) catch |err| {
                        return step.fail("unable to read symlink '{f}/{s}': {s}", .{
                            src_dir_path, entry.path, @errorName(err),
                        });
                    };
                    // `and` は短絡するので、リンクの作成を先に済ませて
                    // から結果を畳み込む。
                    const cached = try installSymLink(step, target, dest_path);
                    all_cached = all_cached and cached;
                    entry_count += 1;
                },
                else => continue,
            }
        }

        // tic は terminfo ソースの解析に失敗しても終了コード 0 を返し、
        // 空の出力ディレクトリを残す。ここで気付かないと terminfo 抜きの
        // 成果物が黙って出来上がるので、install するものが無ければ失敗
        // させる。
        if (entry_count == 0) {
            return step.fail("terminfo database '{f}' is empty", .{src_dir_path});
        }

        step.result_cached = all_cached;
    }

    /// 既に同じ内容のリンクがあれば true (キャッシュ済み) を返す。リンク
    /// 先を解決せずそのまま複製するのは、tic が出す
    /// `.././x/xterm-ghostty` が相対リンクで、install prefix 内で自己完結
    /// させたいため。
    fn installSymLink(
        step: *std.Build.Step,
        target: []const u8,
        dest_path: []const u8,
    ) !bool {
        const cwd = std.fs.cwd();

        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (cwd.readLink(dest_path, &buf)) |existing| {
            if (std.mem.eql(u8, existing, target)) return true;
        } else |_| {}

        _ = try step.installDir(std.fs.path.dirname(dest_path) orelse ".");
        cwd.deleteFile(dest_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return step.fail("unable to remove '{s}': {s}", .{
                dest_path, @errorName(err),
            }),
        };
        cwd.symLink(target, dest_path, .{}) catch |err| {
            return step.fail("unable to create symlink '{s}' -> '{s}': {s}", .{
                dest_path, target, @errorName(err),
            });
        };
        return false;
    }
};
