const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const handler = @import("handler.zig");
const row_mod = @import("row.zig");
const style = @import("style.zig");

pub const Color = style.Color;
pub const Underline = style.Underline;
pub const Style = style.Style;
pub const Span = style.Span;

/// scrolled_off の各行。Row と DirtyRow で所有権の解放ロジックが重複するが、
/// DirtyRow は行番号を持つため型を分けている。
pub const Row = row_mod.Extracted;

pub const DirtyRow = struct {
    row: usize,
    text: []u8,
    spans: []Span,

    pub fn deinit(self: *DirtyRow, alloc: std.mem.Allocator) void {
        for (self.spans) |*s| s.deinit(alloc);
        alloc.free(self.spans);
        alloc.free(self.text);
        self.* = undefined;
    }
};

pub const Cursor = struct {
    row: usize,
    col: usize,
    visible: bool,
};

pub const AltScreen = enum {
    unchanged,
    entered,
    left,
};

pub const Update = struct {
    alloc: std.mem.Allocator,
    dirty: []DirtyRow,
    scrolled_off: []Row,
    cursor: Cursor,
    responses: []u8,
    alt_screen: AltScreen,
    title: ?[]u8,

    pub fn deinit(self: *Update) void {
        for (self.dirty) |*d| d.deinit(self.alloc);
        self.alloc.free(self.dirty);
        for (self.scrolled_off) |*r| r.deinit(self.alloc);
        self.alloc.free(self.scrolled_off);
        self.alloc.free(self.responses);
        if (self.title) |t| self.alloc.free(t);
        self.* = undefined;
    }
};

/// Term は必ずヒープに置く。Handler が自身の responses/pending_title
/// フィールドへ書き戻すために *Term を自己参照するので、値が移動しない
/// (アドレスが安定している) ことが前提になる。
pub const Term = struct {
    alloc: std.mem.Allocator,
    terminal: ghostty_vt.Terminal,
    render: ghostty_vt.RenderState = .empty,
    stream: handler.Stream,
    responses: std.ArrayList(u8) = .empty,
    pending_title: ?[]u8 = null,
    in_alt_screen: bool = false,

    pub fn init(alloc: std.mem.Allocator, rows: u16, cols: u16) !*Term {
        const self = try alloc.create(Term);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .terminal = try .init(alloc, .{ .rows = rows, .cols = cols }),
            .stream = undefined,
        };
        self.stream = .initAlloc(alloc, .init(
            &self.terminal,
            alloc,
            &self.responses,
            &self.pending_title,
        ));

        return self;
    }

    pub fn deinit(self: *Term) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.render.deinit(alloc);
        self.terminal.deinit(alloc);
        self.responses.deinit(alloc);
        if (self.pending_title) |t| alloc.free(t);
        self.* = undefined;
        alloc.destroy(self);
    }

    /// PTY からのバイト列を1つの状態機械に食わせる。エスケープシーケンスが
    /// 複数回の feed に跨って分割される可能性があるため、Parser の状態は
    /// self.stream に永続化してあり、呼び出しごとに作り直さない。
    pub fn feed(self: *Term, alloc: std.mem.Allocator, bytes: []const u8) !Update {
        try self.stream.nextSlice(bytes);
        return self.buildUpdate(alloc);
    }

    pub fn resize(self: *Term, alloc: std.mem.Allocator, rows: u16, cols: u16) !Update {
        try self.terminal.resize(self.alloc, cols, rows);
        return self.buildUpdate(alloc);
    }

    pub fn encodeKey(self: *Term, alloc: std.mem.Allocator, event: ghostty_vt.input.KeyEvent) !?[]u8 {
        var opts = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        opts.macos_option_as_alt = .false;

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try ghostty_vt.input.encodeKey(&aw.writer, event, opts);

        if (aw.written().len == 0) return null;
        return try aw.toOwnedSlice();
    }

    pub fn encodePaste(self: *Term, alloc: std.mem.Allocator, text: []const u8) ![]u8 {
        const opts = ghostty_vt.input.PasteOptions.fromTerminal(&self.terminal);

        const mutable = try alloc.dupe(u8, text);
        defer alloc.free(mutable);
        const parts = ghostty_vt.input.encodePaste(mutable, opts);

        var total: usize = 0;
        for (parts) |p| total += p.len;

        const out = try alloc.alloc(u8, total);
        errdefer alloc.free(out);
        var off: usize = 0;
        for (parts) |p| {
            @memcpy(out[off..][0..p.len], p);
            off += p.len;
        }
        return out;
    }

    fn buildUpdate(self: *Term, alloc: std.mem.Allocator) !Update {
        const alt_screen: AltScreen = alt: {
            const now_alt = self.terminal.screens.active_key == .alternate;
            defer self.in_alt_screen = now_alt;
            if (now_alt == self.in_alt_screen) break :alt .unchanged;
            break :alt if (now_alt) .entered else .left;
        };

        // alternate screen は max_scrollback=0 で初期化されるため
        // (ghostty ScreenSet.getInit)、active が primary のときだけ見ればよい。
        var scrolled_off: std.ArrayList(Row) = .empty;
        errdefer {
            for (scrolled_off.items) |*r| r.deinit(alloc);
            scrolled_off.deinit(alloc);
        }
        if (self.terminal.screens.active_key == .primary) {
            var it = self.terminal.screens.active.pages.rowIterator(
                .right_down,
                .{ .history = .{} },
                null,
            );
            while (it.next()) |pin| {
                const extracted = try row_mod.extractRow(alloc, pin);
                try scrolled_off.append(alloc, extracted);
            }
            // 取り出した分は消して、次回 feed で重複して返さないようにする。
            if (scrolled_off.items.len > 0) {
                self.terminal.eraseDisplay(.scrollback, false);
            }
        }

        try self.render.update(self.alloc, &self.terminal);

        var dirty: std.ArrayList(DirtyRow) = .empty;
        errdefer {
            for (dirty.items) |*d| d.deinit(alloc);
            dirty.deinit(alloc);
        }
        const row_pins = self.render.row_data.items(.pin);
        const row_dirty = self.render.row_data.items(.dirty);
        const rows: usize = self.render.rows;
        for (0..rows) |y| {
            if (!row_dirty[y]) continue;
            const extracted = try row_mod.extractRow(alloc, row_pins[y]);
            try dirty.append(alloc, .{ .row = y, .text = extracted.text, .spans = extracted.spans });
        }

        const cursor: Cursor = .{
            .row = self.render.cursor.active.y,
            .col = self.render.cursor.active.x,
            .visible = self.render.cursor.visible,
        };

        const responses = try alloc.dupe(u8, self.responses.items);
        self.responses.clearRetainingCapacity();

        var title: ?[]u8 = null;
        if (self.pending_title) |t| {
            title = try alloc.dupe(u8, t);
            self.alloc.free(t);
            self.pending_title = null;
        }

        return .{
            .alloc = alloc,
            .dirty = try dirty.toOwnedSlice(alloc),
            .scrolled_off = try scrolled_off.toOwnedSlice(alloc),
            .cursor = cursor,
            .responses = responses,
            .alt_screen = alt_screen,
            .title = title,
        };
    }
};

const testing = std.testing;

// ghostty-vt のダーティ判定はページ単位 (page.dirty) が優先され、同一
// ページに収まる行は書き換えが1行でも全行がダーティ扱いになる。行数1の
// 端末を使うと、その粗さに影響されずに「対象行が dirty に含まれ、
// 期待する内容を持つか」だけを検証できる。
test "feed は SGR 16色の span を抽出する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[31mHi\x1b[0m");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 1), update.dirty.len);
    try testing.expectEqual(@as(usize, 0), update.dirty[0].row);
    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    const span = update.dirty[0].spans[0];
    try testing.expectEqual(@as(usize, 0), span.start);
    try testing.expectEqual(@as(usize, 2), span.end);
    try testing.expect(Color.eql(span.style.fg, .{ .palette = 1 }));
}

test "feed は 256色の span を抽出する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[38;5;208mHi");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(Color.eql(update.dirty[0].spans[0].style.fg, .{ .palette = 208 }));
}

test "feed は 24bit色の span を抽出する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[38;2;10;20;30mHi");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(Color.eql(
        update.dirty[0].spans[0].style.fg,
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
}

test "CRによる行上書きは同じ行を再びダーティにする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "abc");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 1), update.dirty.len);
        try testing.expectEqual(@as(usize, 0), update.dirty[0].row);
        try testing.expectEqualStrings("abc       ", update.dirty[0].text);
    }

    {
        var update = try t.feed(alloc, "\rXY");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 1), update.dirty.len);
        try testing.expectEqual(@as(usize, 0), update.dirty[0].row);
        try testing.expectEqualStrings("XYc       ", update.dirty[0].text);
    }
}

test "スクロールアウトした行は重複なく抽出される" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 5);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "1\r\n2\r\n3\r\n4\r\n");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 2), update.scrolled_off.len);
        try testing.expectEqualStrings("1    ", update.scrolled_off[0].text);
        try testing.expectEqualStrings("2    ", update.scrolled_off[1].text);
    }

    {
        var update = try t.feed(alloc, "");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 0), update.scrolled_off.len);
    }
}

test "alt screen への出入りが通知される" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[?1049h");
        defer update.deinit();
        try testing.expectEqual(AltScreen.entered, update.alt_screen);
    }

    {
        var update = try t.feed(alloc, "hi");
        defer update.deinit();
        try testing.expectEqual(AltScreen.unchanged, update.alt_screen);
    }

    {
        var update = try t.feed(alloc, "\x1b[?1049l");
        defer update.deinit();
        try testing.expectEqual(AltScreen.left, update.alt_screen);
    }
}

test "alt screen 中の描画は scrolled_off に混入しない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 5);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1049h1\r\n2\r\n3\r\n4\r\n");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 0), update.scrolled_off.len);
}

test "resize は全行をダーティにする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "hi");
        defer update.deinit();
    }

    var update = try t.resize(alloc, 8, 10);
    defer update.deinit();
    try testing.expectEqual(@as(usize, 8), update.dirty.len);
}

test "DSR (ESC[6n) はカーソル位置で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "Hi\x1b[6n");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[1;3R", update.responses);
}

test "OSC 2 はタイトル変更を通知する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]2;hello\x07");
    defer update.deinit();
    try testing.expect(update.title != null);
    try testing.expectEqualStrings("hello", update.title.?);
}

test "encodeKey は DECCKM の on/off で矢印キーのエンコードが変わる" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        const bytes = try t.encodeKey(alloc, .{ .key = .arrow_up });
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1b[A", bytes.?);
    }

    {
        var update = try t.feed(alloc, "\x1b[?1h");
        defer update.deinit();
    }

    {
        const bytes = try t.encodeKey(alloc, .{ .key = .arrow_up });
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1bOA", bytes.?);
    }
}

test "encodePaste は bracketed paste モードに追従する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        const bytes = try t.encodePaste(alloc, "hi");
        defer alloc.free(bytes);
        try testing.expectEqualStrings("hi", bytes);
    }

    {
        var update = try t.feed(alloc, "\x1b[?2004h");
        defer update.deinit();
    }

    {
        const bytes = try t.encodePaste(alloc, "hi");
        defer alloc.free(bytes);
        try testing.expectEqualStrings("\x1b[200~hi\x1b[201~", bytes);
    }
}
