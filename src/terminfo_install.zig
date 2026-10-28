//! ビルド時にのみ実行される小さな install 用 exe。`tic` が生成した
//! terminfo データベースのディレクトリ (第 1 引数) を install prefix 側
//! (第 2 引数) へ複製する。`std.Build.Step.InstallDir` を使わないのは、
//! tic が別名 `ghostty` を `x/xterm-ghostty` へのシンボリックリンクとして
//! 出力するのに対し、InstallDir はディレクトリと通常ファイル以外の
//! エントリを読み飛ばす (zig 0.17.0 の lib/compiler/Maker/Step/InstallDir.zig)
//! ため、リンクが install されず TERM=ghostty を引けなくなるから。
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) std.process.fatal("usage: {s} SOURCE_DIR DEST_DIR", .{args[0]});
    const src_path = args[1];
    const dest_path = args[2];

    const cwd = Io.Dir.cwd();
    var src_dir = cwd.openDir(io, src_path, .{ .iterate = true }) catch |err|
        std.process.fatal("unable to open terminfo directory '{s}': {t}", .{ src_path, err });
    defer src_dir.close(io);
    var dest_dir = try cwd.createDirPathOpen(io, dest_path, .{});
    defer dest_dir.close(io);

    var entry_count: usize = 0;
    var it = try src_dir.walk(init.gpa);
    defer it.deinit();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dest_dir.createDirPath(io, entry.path),
            .file => {
                _ = try src_dir.updateFile(io, entry.path, dest_dir, entry.path, .{});
                entry_count += 1;
            },
            .sym_link => {
                try installSymLink(io, src_dir, dest_dir, entry.path);
                entry_count += 1;
            },
            else => continue,
        }
    }

    // tic は terminfo ソースの解析に失敗しても終了コード 0 を返し、
    // 空の出力ディレクトリを残す。ここで気付かないと terminfo 抜きの
    // 成果物が黙って出来上がるので、install するものが無ければ失敗
    // させる。
    if (entry_count == 0) std.process.fatal("terminfo database '{s}' is empty", .{src_path});
}

/// リンク先を解決せずそのまま複製するのは、tic が出す
/// `.././x/xterm-ghostty` が相対リンクで、install prefix 内で自己完結
/// させたいため。
fn installSymLink(io: Io, src_dir: Io.Dir, dest_dir: Io.Dir, path: []const u8) !void {
    var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const target = target_buf[0..try src_dir.readLink(io, path, &target_buf)];

    var existing_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (dest_dir.readLink(io, path, &existing_buf)) |n| {
        if (std.mem.eql(u8, existing_buf[0..n], target)) return;
    } else |_| {}

    try dest_dir.createDirPath(io, std.fs.path.dirname(path) orelse ".");
    dest_dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try dest_dir.symLink(io, target, path, .{});
}
