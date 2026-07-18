//! ビルド時にのみ実行される小さな生成 exe。ghostty 本体の
//! `src/terminfo/main.zig` (std のみに依存する自己完結モジュール、
//! `ghostty-terminfo` として build.zig からモジュール import している)
//! が持つ `xterm-ghostty` の terminfo 定義を、terminfo ソース形式で
//! 標準出力へ書き出すだけ。build.zig がこの出力を `tic` に渡して
//! share/terminfo データベースへコンパイルする。
const std = @import("std");
const ghostty_terminfo = @import("ghostty-terminfo");

pub fn main() !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout_writer.interface;
    try ghostty_terminfo.ghostty.encode(writer);
    try stdout_writer.end();
}
