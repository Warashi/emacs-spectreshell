//! 子のクリップボード操作を、外側の端末へ中継せず Emacs のクリップボード
//! (kill-ring など) で受けるための要求の記録。モジュールは feed の中で
//! Elisp を呼ばず、要求を update に載せるだけにする。kill-ring の操作や
//! 確認は、Elisp が feed の後に行う (docs/design.org の判断 19)。
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const vt_clipboard = ghostty_vt.clipboard;

/// 書き込み先。OSC 52 の s (selection) と p は Emacs では区別できない
/// ので、どちらも primary にする。
pub const Location = enum {
    clipboard,
    primary,

    pub fn fromVt(loc: vt_clipboard.Location) Location {
        return switch (loc) {
            .selection, .primary => .primary,
            .standard, _ => .clipboard,
        };
    }
};

/// update に載せて Elisp へ渡す要求。子が出した順に並ぶ。
pub const Request = union(enum) {
    write: Write,

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .write => |w| alloc.free(w.text),
        }
        self.* = undefined;
    }

    fn clone(self: Request, alloc: std.mem.Allocator) !Request {
        return switch (self) {
            .write => |w| .{ .write = .{ .loc = w.loc, .text = try alloc.dupe(u8, w.text) } },
        };
    }
};

/// 書き込み。TEXT は子が書いた text の中身 (base64 を解いたバイト列)。
pub const Write = struct {
    loc: Location,
    text: []u8,
};

pub fn deinitAll(alloc: std.mem.Allocator, requests: []Request) void {
    for (requests) |*r| r.deinit(alloc);
    alloc.free(requests);
}

/// Term が持つ、まだ update に載せていない要求。
pub const State = struct {
    requests: std.ArrayList(Request) = .empty,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (self.requests.items) |*r| r.deinit(alloc);
        self.requests.deinit(alloc);
    }

    /// 上流の clipboard_write effect に渡された書き込みを記録する。text
    /// の表現が無いものと、空の書き込み (消去) は記録しない。
    pub fn recordWrite(self: *State, alloc: std.mem.Allocator, write: vt_clipboard.Write) !void {
        const text = for (write.contents) |c| {
            if (vt_clipboard.isTextMime(c.mime)) break c.data;
        } else return;
        if (text.len == 0) return;
        const owned = try alloc.dupe(u8, text);
        errdefer alloc.free(owned);
        try self.requests.append(alloc, .{ .write = .{
            .loc = .fromVt(write.location),
            .text = owned,
        } });
    }

    /// 記録した要求を TO に写して返し、記録を空にする。Term と Update で
    /// 確保元が違う (Update は呼び出しごとの arena) ので移さず写す。
    /// 失敗したときは記録をそのまま残す。
    pub fn take(self: *State, from: std.mem.Allocator, to: std.mem.Allocator) ![]Request {
        const out = try to.alloc(Request, self.requests.items.len);
        var copied: usize = 0;
        errdefer {
            for (out[0..copied]) |*r| r.deinit(to);
            to.free(out);
        }
        for (self.requests.items) |r| {
            out[copied] = try r.clone(to);
            copied += 1;
        }
        for (self.requests.items) |*r| r.deinit(from);
        self.requests.clearRetainingCapacity();
        return out;
    }
};

const testing = std.testing;
const core = @import("core.zig");

test "OSC 52 の書き込みは base64 を解いた text と書き込み先を要求に載せる" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]52;c;aGk=\x07\x1b]52;;eW8=\x1b\\\x1b]52;p;44GC\x07\x1b]52;s;YQ==\x07\x1b]52;0;Yg==\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 5), update.clipboard.len);
    const want = [_]struct { Location, []const u8 }{
        .{ .clipboard, "hi" },
        .{ .clipboard, "yo" },
        .{ .primary, "\u{3042}" },
        .{ .primary, "a" },
        .{ .clipboard, "b" },
    };
    for (want, update.clipboard) |w, got| {
        try testing.expectEqual(w[0], got.write.loc);
        try testing.expectEqualStrings(w[1], got.write.text);
    }
}

test "OSC 52 の空の書き込みと base64 でない書き込みは載せない" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]52;c;\x07\x1b]52;c;a!b=\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
}

test "mode 2026 の中でもクリップボードの要求は保留しない" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?2026h\x1b]52;c;aGk=\x07");
    defer update.deinit();
    try testing.expect(update.synchronized);
    try testing.expectEqual(@as(usize, 1), update.clipboard.len);
}

test "要求を渡す前に Term を捨ててもリークしない" {
    const t = try core.Term.init(testing.allocator, 5, 10);
    var update = try t.feed(testing.allocator, "\x1b[?2026h");
    update.deinit();
    t.stream.nextSlice("\x1b]52;c;aGk=\x07");
    t.deinit();
}

test "要求を載せる途中で確保に失敗してもリークしない" {
    const S = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const t = try core.Term.init(testing.allocator, 2, 5);
            defer t.deinit();
            var update = try t.feed(alloc, "\x1b]52;c;aGk=\x07\x1b]52;p;eW8=\x07");
            update.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}

test "OSC 52 を受けた後も、OSC 10 には 1 回だけ答え、OSC 21 には答えない" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    t.setColors(.{ .foreground = .{ .r = 1, .g = 2, .b = 3 } });
    var update = try t.feed(alloc, "\x1b]52;c;aGk=\x07\x1b]10;?\x07\x1b]21;foreground=?\x07");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b]10;rgb:0001/0002/0003\x07", update.responses);
}

test "OSC 52 を受けた後も、mode 2033 を立てたときの報告は 1 回だけ" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]52;c;aGk=\x07\x1b[?2033h");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?999;1n", update.responses);
}
