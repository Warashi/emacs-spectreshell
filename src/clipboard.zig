//! 子のクリップボード操作を、外側の端末へ中継せず Emacs のクリップボード
//! (kill-ring など) で受けるための要求の記録。モジュールは feed の中で
//! Elisp を呼ばず、要求を update に載せるだけにする。kill-ring の操作や
//! 確認は、Elisp が feed の後に行う (docs/design.org の判断 19)。
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const vt_clipboard = ghostty_vt.clipboard;
const kitty = ghostty_vt.kitty.clipboard;

/// 子の書き込みを受けるか (spectreshell-clipboard-write)。モジュールが
/// 区別するのは deny だけで、ask の確認は Elisp が後で行う。
pub const WritePolicy = enum { allow, ask, deny };

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
            .write => |w| {
                alloc.free(w.text);
                alloc.free(w.name);
            },
            .read => |r| alloc.free(r.name),
        }
        self.* = undefined;
    }

    fn clone(self: Request, alloc: std.mem.Allocator) !Request {
        switch (self) {
            .write => |w| {
                var copy = w;
                copy.text = try alloc.dupe(u8, w.text);
                errdefer alloc.free(copy.text);
                copy.name = try alloc.dupe(u8, w.name);
                return .{ .write = copy };
            },
            .read => |r| {
                var copy = r;
                copy.name = try alloc.dupe(u8, r.name);
                return .{ .read = copy };
            },
        }
    }
};

/// 書き込み。TEXT は子が書いた text の中身 (base64 を解いたバイト列)。
/// NAME 以降は OSC 5522 の名前とパスワードによるもの。
pub const Write = struct {
    loc: Location,
    text: []u8,
    /// 覚えられる (REMEMBER) ときだけ振る。Elisp は Term.clipboardReply で
    /// 覚えるかを答える。
    id: ?u64 = null,
    /// 子が名乗った名前 (UTF-8)。無ければ空。
    name: []u8 = &.{},
    /// すでに覚えたパスワードの書き込み。確認しない。
    granted: bool = false,
    remember: bool = false,
};

/// 読み取り。Elisp は中身を読んで ID とともに Term.clipboardReply に渡し、
/// 返ったバイト列を子へ送る。
pub const Read = struct {
    id: u64,
    loc: Location,
    /// 子が text を求めていない (OSC 5522 の一覧だけ、または text 以外の
    /// MIME だけ)。答えても中身を明かさないので確認しない。
    no_text: bool = false,
    name: []u8 = &.{},
    granted: bool = false,
    remember: bool = false,
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
        kitty_read: KittyRead,
        /// 覚えるかの答えを待つ OSC 5522 の書き込み。PW を覚える。
        kitty_write: []u8,
    };

    fn deinit(self: *Waiting, alloc: std.mem.Allocator) void {
        switch (self.reply) {
            .osc52 => {},
            .kitty_read => |r| r.arena.deinit(),
            .kitty_write => |pw| alloc.free(pw),
        }
        self.* = undefined;
    }
};

/// OSC 5522 の読み取りへの応答。上流の stream_terminal.zig の
/// KittyClipboardReadState (kittyClipboardRead と reply・respondStatus・
/// respondSuccess) に対応する。符号化は上流の Response と ReadSuccess を
/// そのまま使う。
const KittyRead = struct {
    /// 以下のスライスはすべてここから確保する。
    arena: std.heap.ArenaAllocator,
    primary: bool,
    id: []const u8,
    /// 要求された MIME (一覧 . を除く)。答えるのはこのうち text の別名だけ。
    mimes: []const []const u8,
    list: bool,
    pw: []const u8,
    terminator: ghostty_vt.osc.Terminator,

    /// kill-ring は text しか持たないので、一覧には中身によらず
    /// text/plain を答え、text の別名には要求された名前で同じ中身を答える。
    fn encode(
        self: *const KittyRead,
        w: *std.Io.Writer,
        data: ?[]const u8,
    ) std.Io.Writer.Error!void {
        const text = data orelse return (kitty.Response{
            .op = .read,
            .status = .EPERM,
            .id = self.id,
            .terminator = self.terminator,
        }).encode(w);
        var served: [kitty.max_read_mimes]vt_clipboard.Content = undefined;
        var n: usize = 0;
        for (self.mimes) |mime| {
            if (!vt_clipboard.isTextMime(mime)) continue;
            served[n] = .{ .mime = mime, .data = text };
            n += 1;
        }
        try (kitty.ReadSuccess{
            .primary = self.primary,
            .id = self.id,
            .list = self.list,
            .available = &.{"text/plain"},
            .contents = served[0..n],
            .terminator = self.terminator,
        }).encode(w);
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
    write_policy: WritePolicy = .allow,

    pub fn deinit(self: *State, alloc: std.mem.Allocator) void {
        for (self.requests.items) |*r| r.deinit(alloc);
        self.requests.deinit(alloc);
        for (self.waiting.items) |*w| w.deinit(alloc);
        self.waiting.deinit(alloc);
    }

    pub const Recorded = enum { recorded, empty, no_text };

    /// 上流の clipboard_write effect に渡された書き込みを記録する。空の
    /// 書き込み (消去) と text の表現が無いものは記録しない。PW は覚え
    /// られる書き込みのパスワード。
    pub fn recordWrite(
        self: *State,
        alloc: std.mem.Allocator,
        write: vt_clipboard.Write,
        pw: []const u8,
    ) !Recorded {
        if (write.contents.len == 0) return .empty;
        const text = for (write.contents) |c| {
            if (vt_clipboard.isTextMime(c.mime)) break c.data;
        } else return .no_text;
        if (text.len == 0) return .empty;
        var request: Write = .{
            .loc = .fromVt(write.location),
            .text = try alloc.dupe(u8, text),
            .granted = write.granted,
        };
        errdefer alloc.free(request.text);
        request.name = try alloc.dupe(u8, write.name);
        errdefer alloc.free(request.name);
        try self.requests.ensureUnusedCapacity(alloc, 1);
        // 覚えるかの答えを待つ記録が上限なら、覚えられない書き込みにする。
        if (write.can_remember and pw.len > 0 and self.waiting.items.len < max_waiting) {
            const owned_pw = try alloc.dupe(u8, pw);
            errdefer alloc.free(owned_pw);
            try self.waiting.ensureUnusedCapacity(alloc, 1);
            request.id = self.next_id;
            request.remember = true;
            self.next_id += 1;
            self.waiting.appendAssumeCapacity(.{ .id = request.id.?, .reply = .{ .kitty_write = owned_pw } });
        }
        self.requests.appendAssumeCapacity(.{ .write = request });
        return .recorded;
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

    /// OSC 5522 の読み取りを記録する。上流の stream_terminal.zig の
    /// kittyClipboardRead のうち、clipboard_read effect を呼ぶ手前までに
    /// 対応する。不正な要求は上流と同じく答えずに捨て、上限を超えたら
    /// RESPONSES に EBUSY を積む。GRANTS は上流の handler が持つもので、
    /// 一度きりのパスワードはここで使い切る。
    pub fn recordKittyRead(
        self: *State,
        alloc: std.mem.Allocator,
        responses: *std.ArrayList(u8),
        grants: *kitty.Grants,
        metadata: []const u8,
        payload: ?[]const u8,
        terminator: ghostty_vt.osc.Terminator,
    ) !void {
        var arena: std.heap.ArenaAllocator = .init(alloc);
        var kept = false;
        defer if (!kept) arena.deinit();
        const a = arena.allocator();

        const meta = (kitty.Metadata.parse(a, metadata) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => return,
        }) orelse return;
        const decoded = kitty.Payload.init(a, payload orelse "") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return,
        };
        if (!decoded.isValidUtf8()) return;

        if (self.waiting.items.len >= max_waiting) {
            var aw: std.Io.Writer.Allocating = .init(a);
            (kitty.Response{
                .op = .read,
                .status = .EBUSY,
                .id = meta.id,
                .terminator = terminator,
            }).encode(&aw.writer) catch return error.OutOfMemory;
            return responses.appendSlice(alloc, aw.written());
        }

        var mimes: std.ArrayList([]const u8) = .empty;
        var list = false;
        var text = false;
        var it = decoded.mimeIterator();
        while (it.next()) |mime| {
            if (std.mem.eql(u8, mime, kitty.targets_mime)) {
                list = true;
                continue;
            }
            if (mimes.items.len == kitty.max_read_mimes) continue;
            try mimes.append(a, mime);
            if (vt_clipboard.isTextMime(mime)) text = true;
        }

        const name = try alloc.dupe(u8, meta.name);
        errdefer alloc.free(name);
        try self.waiting.ensureUnusedCapacity(alloc, 1);
        try self.requests.ensureUnusedCapacity(alloc, 1);

        // 名前の無いパスワードは無いものとして扱う (上流と同じ)。
        const pw: []const u8 = if (meta.name.len > 0) meta.pw else "";
        const granted = !kitty.readPromptExempt(mimes.items.len) and grants.use(alloc, pw, .read);
        const id = self.next_id;
        self.next_id += 1;
        kept = true;
        self.waiting.appendAssumeCapacity(.{ .id = id, .reply = .{ .kitty_read = .{
            .arena = arena,
            .primary = meta.loc == .primary,
            .id = meta.id,
            .mimes = mimes.items,
            .list = list,
            .pw = pw,
            .terminator = terminator,
        } } });
        self.requests.appendAssumeCapacity(.{ .read = .{
            .id = id,
            .loc = if (meta.loc == .primary) .primary else .clipboard,
            .no_text = !text,
            .name = name,
            .granted = granted,
            .remember = pw.len > 0,
        } });
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

    /// ID の要求への答えを OUT で確保して返す。読み取りは DATA が null
    /// なら断る。REMEMBER なら要求のパスワードを GRANTS に覚える。答える
    /// バイト列の無い書き込みと、答えていない ID でなければ null。答えたら
    /// 記録を消す。
    pub fn reply(
        self: *State,
        alloc: std.mem.Allocator,
        out: std.mem.Allocator,
        grants: *kitty.Grants,
        id: u64,
        data: ?[]const u8,
        remember: bool,
    ) !?[]u8 {
        const index = for (self.waiting.items, 0..) |w, i| {
            if (w.id == id) break i;
        } else return null;
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        const has_bytes = switch (self.waiting.items[index].reply) {
            .osc52 => |r| has: {
                r.encode(&aw.writer, data orelse "") catch return error.OutOfMemory;
                break :has true;
            },
            .kitty_read => |*r| has: {
                if (remember and data != null and r.pw.len > 0) try grants.grant(alloc, r.pw, .read, false);
                r.encode(&aw.writer, data) catch return error.OutOfMemory;
                break :has true;
            },
            .kitty_write => |pw| has: {
                if (remember) try grants.grant(alloc, pw, .write, false);
                break :has false;
            },
        };
        const bytes: ?[]u8 = if (has_bytes) try aw.toOwnedSlice() else null;
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

/// mode 5522 の間の貼り付けで、本文の代わりに子へ送る paste イベントを
/// OUT で確保して返す。mode 5522 でなければ null。上流の terminal/paste.zig
/// の pasteKittyEvent に対応する。上流の paste は clipboard_read effect を
/// 前提にし本文の貼り付けも含むので使わず、イベントの部分だけを持つ。
/// 一覧は text/plain だけ (kill-ring は text しか持たない)。一度きりの
/// パスワードを GRANTS に覚え、続く読み取りを確認なしで通す。
pub fn pasteEvent(
    terminal: *ghostty_vt.Terminal,
    grants: *kitty.Grants,
    alloc: std.mem.Allocator,
    out: std.mem.Allocator,
) !?[]u8 {
    if (!terminal.modes.get(.kitty_paste_events)) return null;
    const otp = try kitty.generateOtp(terminal.io());
    try grants.grant(alloc, &otp, .read, true);
    errdefer _ = grants.use(alloc, &otp, .read);
    var aw: std.Io.Writer.Allocating = .init(out);
    defer aw.deinit();
    (kitty.PasteEvent{
        .pw = &otp,
        .available = &.{"text/plain"},
    }).encode(&aw.writer) catch return error.OutOfMemory;
    return try aw.toOwnedSlice();
}

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
        const bytes = (try t.clipboardReply(alloc, r.read.id, "hi", false)).?;
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
    const bytes = (try t.clipboardReply(alloc, id, null, false)).?;
    defer alloc.free(bytes);
    try testing.expectEqualStrings("\x1b]52;c;\x07", bytes);
    try testing.expectEqual(@as(?[]u8, null), try t.clipboardReply(alloc, id, "hi", false));
    try testing.expectEqual(@as(?[]u8, null), try t.clipboardReply(alloc, id + 1, "hi", false));
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
            const bytes = t.clipboardReply(alloc, id, "hi", false) catch |err| {
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

/// OSC 5522 の 1 パケット (BEL 終端)。
inline fn kittyOsc(comptime meta: []const u8, comptime payload: []const u8) []const u8 {
    return "\x1b]5522;" ++ meta ++ (if (payload.len > 0) ";" ++ payload else "") ++ "\x07";
}

const kitty_text_write = kittyOsc("type=write", "") ++
    kittyOsc("type=wdata:mime=dGV4dC9wbGFpbg==", "aGk=") ++
    kittyOsc("type=wdata", "");

test "OSC 5522 の書き込みは上流が DONE で答え、text を要求に載せる" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kitty_text_write ++
        kittyOsc("type=write:loc=primary", "") ++
        kittyOsc("type=wdata:mime=dGV4dC9wbGFpbjtjaGFyc2V0PXV0Zi04", "eW8=") ++
        kittyOsc("type=wdata", ""));
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]5522;type=write:status=DONE\x07\x1b]5522;type=write:status=DONE\x07",
        update.responses,
    );
    try testing.expectEqual(@as(usize, 2), update.clipboard.len);
    const first = update.clipboard[0].write;
    try testing.expectEqual(Location.clipboard, first.loc);
    try testing.expectEqualStrings("hi", first.text);
    try testing.expectEqual(@as(?u64, null), first.id);
    try testing.expect(!first.granted);
    try testing.expectEqual(Location.primary, update.clipboard[1].write.loc);
    try testing.expectEqualStrings("yo", update.clipboard[1].write.text);
}

test "deny の間の書き込みは載せず、OSC 5522 には EPERM で答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    t.setClipboardWrite(.deny);
    var update = try t.feed(alloc, "\x1b]52;c;aGk=\x07" ++ kitty_text_write);
    defer update.deinit();
    try testing.expectEqualStrings("\x1b]5522;type=write:status=EPERM\x07", update.responses);
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
}

test "text の無い OSC 5522 の書き込みは載せず、ENOSYS で答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kittyOsc("type=write", "") ++
        kittyOsc("type=wdata:mime=aW1hZ2UvcG5n", "AAAA") ++
        kittyOsc("type=wdata", ""));
    defer update.deinit();
    try testing.expectEqualStrings("\x1b]5522;type=write:status=ENOSYS\x07", update.responses);
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
}

test "名前とパスワードの付いた書き込みは覚えられ、覚えると次から許可済みで来る" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    const write = kittyOsc("type=write:name=cHJvZw==:pw=c2VjcmV0", "") ++
        kittyOsc("type=wdata:mime=dGV4dC9wbGFpbg==", "aGk=") ++
        kittyOsc("type=wdata", "");
    var first = try t.feed(alloc, write);
    defer first.deinit();
    const w = first.clipboard[0].write;
    try testing.expectEqualStrings("prog", w.name);
    try testing.expect(w.remember);
    try testing.expect(!w.granted);
    try testing.expectEqual(@as(?[]u8, null), try t.clipboardReply(alloc, w.id.?, null, true));

    var second = try t.feed(alloc, write);
    defer second.deinit();
    try testing.expect(second.clipboard[0].write.granted);
}

test "OSC 5522 の読み取りは feed では答えず、reply で OK・DATA・DONE を要求の終端で返す" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kittyOsc("type=read:id=x1", "dGV4dC9wbGFpbg==") ++
        "\x1b]5522;type=read:loc=primary;dGV4dC9wbGFpbg==\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
    try testing.expectEqual(@as(usize, 2), update.clipboard.len);
    const r = update.clipboard[0].read;
    try testing.expectEqual(Location.clipboard, r.loc);
    try testing.expect(!r.no_text);
    try testing.expect(!r.granted);
    try testing.expect(!r.remember);
    const bytes = (try t.clipboardReply(alloc, r.id, "hi", false)).?;
    defer alloc.free(bytes);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK:id=x1\x07" ++
            "\x1b]5522;type=read:status=DATA:id=x1:mime=dGV4dC9wbGFpbg==;aGk=\x07" ++
            "\x1b]5522;type=read:status=DONE:id=x1\x07",
        bytes,
    );

    const p = update.clipboard[1].read;
    try testing.expectEqual(Location.primary, p.loc);
    const denied = (try t.clipboardReply(alloc, p.id, null, false)).?;
    defer alloc.free(denied);
    try testing.expectEqualStrings("\x1b]5522;type=read:status=EPERM\x1b\\", denied);
}

test "OSC 5522 の text の別名は、要求された名前で同じ中身を答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kittyOsc("type=read", "VVRGOF9TVFJJTkcgdGV4dC9wbGFpbg=="));
    defer update.deinit();
    const bytes = (try t.clipboardReply(alloc, update.clipboard[0].read.id, "hi", false)).?;
    defer alloc.free(bytes);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x07" ++
            "\x1b]5522;type=read:status=DATA:mime=VVRGOF9TVFJJTkc=;aGk=\x07" ++
            "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;aGk=\x07" ++
            "\x1b]5522;type=read:status=DONE\x07",
        bytes,
    );
}

test "OSC 5522 の一覧だけの要求と text 以外だけの要求は中身を求めず、一覧には text/plain を答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kittyOsc("type=read", "Lg==") ++ kittyOsc("type=read", "aW1hZ2UvcG5n"));
    defer update.deinit();
    try testing.expect(update.clipboard[0].read.no_text);
    try testing.expect(update.clipboard[1].read.no_text);
    const listing = (try t.clipboardReply(alloc, update.clipboard[0].read.id, "", false)).?;
    defer alloc.free(listing);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x07" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbgo=\x07" ++
            "\x1b]5522;type=read:status=DONE\x07",
        listing,
    );
    const image = (try t.clipboardReply(alloc, update.clipboard[1].read.id, "", false)).?;
    defer alloc.free(image);
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x07\x1b]5522;type=read:status=DONE\x07",
        image,
    );
}

test "base64 でない OSC 5522 の読み取りは黙って捨てる" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, kittyOsc("type=read", "a!b=") ++ kittyOsc("type=read:name=!!", "dGV4dC9wbGFpbg=="));
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
}

test "読み取りで覚えたパスワードは次から許可済みで来て、RIS で消える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    const read = kittyOsc("type=read:name=cHJvZw==:pw=c2VjcmV0", "dGV4dC9wbGFpbg==");
    var first = try t.feed(alloc, read);
    defer first.deinit();
    const r = first.clipboard[0].read;
    try testing.expectEqualStrings("prog", r.name);
    try testing.expect(r.remember);
    const bytes = (try t.clipboardReply(alloc, r.id, "hi", true)).?;
    alloc.free(bytes);

    var second = try t.feed(alloc, read);
    defer second.deinit();
    try testing.expect(second.clipboard[0].read.granted);

    var third = try t.feed(alloc, "\x1bc" ++ read);
    defer third.deinit();
    try testing.expect(!third.clipboard[0].read.granted);
}

test "答えていない読み取りが上限を超えたら、OSC 5522 には EBUSY で答える" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    for (0..max_waiting) |_| {
        var update = try t.feed(alloc, "\x1b]52;c;?\x07");
        update.deinit();
    }
    var update = try t.feed(alloc, kittyOsc("type=read:id=a", "dGV4dC9wbGFpbg=="));
    defer update.deinit();
    try testing.expectEqual(@as(usize, 0), update.clipboard.len);
    try testing.expectEqualStrings("\x1b]5522;type=read:status=EBUSY:id=a\x07", update.responses);
}

test "paste イベントは mode 5522 の間だけ出し、続く読み取りを一度だけ許可済みにする" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    try testing.expectEqual(@as(?[]u8, null), try t.encodePasteEvent(alloc));
    var on = try t.feed(alloc, "\x1b[?5522h");
    on.deinit();
    const event = (try t.encodePasteEvent(alloc)).?;
    defer alloc.free(event);

    // 上流の PasteEvent の形: OK・一覧 (text/plain)・DONE の各パケットに
    // 同じ一度きりのパスワードが付く。
    const prefix = "\x1b]5522;type=read:status=OK:pw=";
    try testing.expect(std.mem.startsWith(u8, event, prefix));
    const pw = event[prefix.len..std.mem.indexOfPos(u8, event, prefix.len, "\x1b\\").?];
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);
    try expected.print(alloc, "{s}{s}\x1b\\" ++
        "\x1b]5522;type=read:status=DATA:mime=Lg==:pw={s};dGV4dC9wbGFpbgo=\x1b\\" ++
        "\x1b]5522;type=read:status=DONE:pw={s}\x1b\\", .{ prefix, pw, pw, pw });
    try testing.expectEqualStrings(expected.items, event);

    var follow: std.ArrayList(u8) = .empty;
    defer follow.deinit(alloc);
    // 一覧だけの要求は grant を使わないので、続くデータの要求に残る。
    try follow.print(alloc, "\x1b]5522;type=read:name=UGFzdGUgZXZlbnQ=:pw={s};Lg==\x07", .{pw});
    try follow.print(alloc, "\x1b]5522;type=read:name=UGFzdGUgZXZlbnQ=:pw={s};dGV4dC9wbGFpbg==\x07", .{pw});
    try follow.print(alloc, "\x1b]5522;type=read:name=UGFzdGUgZXZlbnQ=:pw={s};dGV4dC9wbGFpbg==\x07", .{pw});
    var update = try t.feed(alloc, follow.items);
    defer update.deinit();
    try testing.expect(!update.clipboard[0].read.granted);
    try testing.expect(update.clipboard[1].read.granted);
    try testing.expect(!update.clipboard[2].read.granted);
}

test "OSC 5522 を受けた後も、OSC 10 には 1 回だけ答え、OSC 21 には答えず、mode 2033 の報告は 1 回だけ" {
    const alloc = testing.allocator;
    const t = try core.Term.init(alloc, 5, 10);
    defer t.deinit();

    t.setColors(.{ .foreground = .{ .r = 1, .g = 2, .b = 3 } });
    var update = try t.feed(alloc, kitty_text_write ++ kittyOsc("type=read", "dGV4dC9wbGFpbg==") ++
        "\x1b]10;?\x07\x1b]21;foreground=?\x07\x1b[?2033h");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]5522;type=write:status=DONE\x07\x1b]10;rgb:0001/0002/0003\x07\x1b[?999;1n",
        update.responses,
    );
}

test "OSC 5522 の読み取りの記録と応答の途中で確保に失敗してもリークせず、要求と記録の数がそろう" {
    const S = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var state: State = .{};
            defer state.deinit(alloc);
            var grants: kitty.Grants = .{};
            defer grants.deinit(alloc);
            var responses: std.ArrayList(u8) = .empty;
            defer responses.deinit(alloc);
            state.recordKittyRead(alloc, &responses, &grants, "type=read:id=a:name=cHJvZw==:pw=c2VjcmV0", "LiB0ZXh0L3BsYWlu", .bel) catch |err| {
                try testing.expectEqual(state.requests.items.len, state.waiting.items.len);
                return err;
            };
            const id = state.requests.items[0].read.id;
            const bytes = try state.reply(alloc, alloc, &grants, id, "hi", true);
            alloc.free(bytes.?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
}
