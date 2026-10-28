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

/// 答えていない読み取りの上限。子が問い合わせを出し続けても、確認を
/// 待つ間に記録が際限なく増えないようにする。超えた分は待たせずに断る。
pub const max_waiting = 64;

/// update に載せて Elisp へ渡す要求。子が出した順に並ぶ。
pub const Request = union(enum) {
    write: Write,
    read: Read,

    pub fn deinit(self: *Request, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .write => |w| alloc.free(w.text),
            .read => {},
        }
        self.* = undefined;
    }

    fn clone(self: Request, alloc: std.mem.Allocator) !Request {
        return switch (self) {
            .write => |w| .{ .write = .{ .loc = w.loc, .text = try alloc.dupe(u8, w.text) } },
            .read => self,
        };
    }
};

/// 書き込み。TEXT は子が書いた text の中身 (base64 を解いたバイト列)。
pub const Write = struct {
    loc: Location,
    text: []u8,
};

/// 読み取り。Elisp は中身を読んで ID とともに Term.clipboardReply に渡し、
/// 返ったバイト列を子へ送る。
pub const Read = struct {
    id: u64,
    loc: Location,
};

pub fn deinitAll(alloc: std.mem.Allocator, requests: []Request) void {
    for (requests) |*r| r.deinit(alloc);
    alloc.free(requests);
}

/// 答えていない読み取りの、応答を組み立てるのに要るもの。
const Waiting = struct {
    id: u64,
    reply: Reply,

    const Reply = union(enum) {
        osc52: Osc52,
    };

    fn deinit(self: *Waiting, alloc: std.mem.Allocator) void {
        _ = alloc;
        switch (self.reply) {
            .osc52 => {},
        }
        self.* = undefined;
    }
};

/// OSC 52 の読み取りへの応答。上流の stream_terminal.zig の
/// ClipboardReadState (clipboardRead と respond) に対応する。上流は読み取り
/// を feed の中で同期に答えるので、後で答えるためにここで持つ。
const Osc52 = struct {
    /// 答えに書く種別。要求に合わせ、s と p 以外は c にする。
    kind: u8,
    terminator: ghostty_vt.osc.Terminator,

    fn init(kind: u8, terminator: ghostty_vt.osc.Terminator) Osc52 {
        return .{
            .kind = switch (kind) {
                's', 'p' => kind,
                else => 'c',
            },
            .terminator = terminator,
        };
    }

    /// 断ったときは、子を待たせないよう上流と同じく空で答える。
    fn encode(self: Osc52, w: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
        try w.print("\x1b]52;{c};", .{self.kind});
        try std.base64.standard.Encoder.encodeWriter(w, data);
        try w.writeAll(self.terminator.string());
    }
};

/// Term が持つ、まだ update に載せていない要求と、答えていない読み取り。
pub const State = struct {
    requests: std.ArrayList(Request) = .empty,
    waiting: std.ArrayList(Waiting) = .empty,
    next_id: u64 = 1,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (self.requests.items) |*r| r.deinit(alloc);
        self.requests.deinit(alloc);
        for (self.waiting.items) |*w| w.deinit(alloc);
        self.waiting.deinit(alloc);
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

    /// OSC 52 の読み取り (?) を記録する。種別によらず標準のクリップボード
    /// を読む。上限を超えたら RESPONSES に空の答えを積む。
    pub fn recordOsc52Read(
        self: *State,
        alloc: std.mem.Allocator,
        responses: *std.ArrayList(u8),
        kind: u8,
        terminator: ghostty_vt.osc.Terminator,
    ) !void {
        const answer: Osc52 = .init(kind, terminator);
        if (self.waiting.items.len >= max_waiting) {
            var buf: [16]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            answer.encode(&w, "") catch unreachable;
            return responses.appendSlice(alloc, w.buffered());
        }
        try self.addRead(alloc, .{ .osc52 = answer }, .clipboard);
    }

    /// 要求と記録を両方積むか、どちらも積まない。
    fn addRead(self: *State, alloc: std.mem.Allocator, answer: Waiting.Reply, loc: Location) !void {
        try self.waiting.ensureUnusedCapacity(alloc, 1);
        try self.requests.ensureUnusedCapacity(alloc, 1);
        const id = self.next_id;
        self.next_id += 1;
        self.waiting.appendAssumeCapacity(.{ .id = id, .reply = answer });
        self.requests.appendAssumeCapacity(.{ .read = .{ .id = id, .loc = loc } });
    }

    /// ID の読み取りへの答えを OUT で確保して返す。DATA が null なら断る。
    /// 答えていない ID でなければ null。答えたら記録を消す。
    pub fn reply(
        self: *State,
        alloc: std.mem.Allocator,
        out: std.mem.Allocator,
        id: u64,
        data: ?[]const u8,
    ) !?[]u8 {
        const index = for (self.waiting.items, 0..) |w, i| {
            if (w.id == id) break i;
        } else return null;
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        switch (self.waiting.items[index].reply) {
            .osc52 => |r| r.encode(&aw.writer, data orelse "") catch return error.OutOfMemory,
        }
        const bytes = try aw.toOwnedSlice();
        var done = self.waiting.orderedRemove(index);
        done.deinit(alloc);
        return bytes;
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

test "OSC 52 の読み取りは id を振った要求を載せ、reply で要求と同じ種別と終端で答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]52;c;?\x07\x1b]52;p;?\x1b\\\x1b]52;s;?\x07\x1b]52;0;?\x07");
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
    try testing.expectEqual(@as(usize, 4), update.clipboard.len);
    const want = [_][]const u8{
        "\x1b]52;c;aGk=\x07",
        "\x1b]52;p;aGk=\x1b\\",
        "\x1b]52;s;aGk=\x07",
        "\x1b]52;c;aGk=\x07",
    };
    for (want, update.clipboard) |w, r| {
        // 種別によらず標準のクリップボードを読む。
        try testing.expectEqual(Location.clipboard, r.read.loc);
        const bytes = (try t.clipboardReply(alloc, r.read.id, "hi")).?;
        defer alloc.free(bytes);
        try testing.expectEqualStrings(w, bytes);
    }
}

test "OSC 52 の読み取りを断ると空で答え、同じ id には二度答えない" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]52;c;?\x07");
    defer update.deinit();
    const id = update.clipboard[0].read.id;
    const bytes = (try t.clipboardReply(alloc, id, null)).?;
    defer alloc.free(bytes);
    try testing.expectEqualStrings("\x1b]52;c;\x07", bytes);
    try testing.expectEqual(@as(?[]u8, null), try t.clipboardReply(alloc, id, "hi"));
    try testing.expectEqual(@as(?[]u8, null), try t.clipboardReply(alloc, id + 1, "hi"));
}

test "答えていない読み取りが上限を超えたら、それ以上は待たせずに空で答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    for (0..max_waiting) |_| {
        var update = try t.feed(alloc, "\x1b]52;c;?\x07");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 1), update.clipboard.len);
    }
    var update = try t.feed(alloc, "\x1b]52;c;?\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
    try testing.expectEqualStrings("\x1b]52;c;\x07", update.responses);
}

test "答える前に Term を捨てても読み取りの記録はリークしない" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    var update = try t.feed(alloc, "\x1b]52;c;?\x07\x1b]52;c;?\x07");
    update.deinit();
    t.deinit();
}

test "読み取りの応答の途中で確保に失敗してもリークせず、記録も残る" {
    const S = struct {
        fn run(alloc: std.mem.Allocator) !void {
            // Term 側に失敗を注入すると上流の OSC パーサが assert で落ちる
            // ので、Term は安定した確保元に置き、update と応答の側にだけ
            // 注入する。記録の側は State 単体のテストで見る。
            const t = try core.Term.init(testing.allocator, 2, 5);
            defer t.deinit();
            var update = try t.feed(alloc, "\x1b]52;c;?\x07");
            defer update.deinit();
            const id = update.clipboard[0].read.id;
            const bytes = t.clipboardReply(alloc, id, "hi") catch |err| {
                try testing.expectEqual(@as(usize, 1), t.clipboard.waiting.items.len);
                return err;
            };
            alloc.free(bytes.?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}

test "読み取りの記録の途中で確保に失敗したら、要求も記録も積まない" {
    const S = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var state: State = .{};
            defer state.deinit(alloc);
            var responses: std.ArrayList(u8) = .empty;
            defer responses.deinit(alloc);
            state.recordOsc52Read(alloc, &responses, 'c', .bel) catch |err| {
                try testing.expectEqual(state.requests.items.len, state.waiting.items.len);
                return err;
            };
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}
