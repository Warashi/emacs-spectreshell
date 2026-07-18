const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const handler = @import("handler.zig");
const row_mod = @import("row.zig");
const style = @import("style.zig");

pub const Color = style.Color;
pub const Underline = style.Underline;
pub const Style = style.Style;
pub const Span = style.Span;

/// UTF-8 マウス報告 (mode 1005) の1座標分。32 (SP) + 1-origin 変換込みの
/// コードポイントを直接 UTF-8 で書く (xterm の実装に合わせて西暦2000年
/// 問題ならぬ「座標223超えでバイトが衝突する」x10 形式の限界を回避する)。
fn writeUtf8Coord(w: *std.Io.Writer, coord: usize) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(@intCast(32 + coord + 1), &buf);
    try w.writeAll(buf[0..n]);
}

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

/// design.org の BUTTON 中間表現。ghostty-vt はマウスレポートのエンコーダを
/// 公開していないため (design.org 前提の調査結果)、ghostty 本体
/// src/Surface.zig の mouseReport のボタン番号割り当てをそのまま踏襲する。
pub const MouseButton = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
};

pub const MouseAction = enum { press, release, motion };

/// mouseReport は super を見ないので (ctrl/alt/shift のみビット割り当てが
/// ある)、encode-key の MODIFIERS と違いここでは super を受け付けない。
pub const MouseMods = struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
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

    /// ghostty 本体 src/Surface.zig の mouseReport を、Emacs 側が既に
    /// セル単位の (ROW, COL) しか持っていない前提に合わせて移植したもの。
    /// pos_out_viewport 判定 (画面外座標の間引き) は呼び出し側 (Elisp) が
    /// バッファ座標から計算する時点で常に端末領域内に収まるため省略し、
    /// sgr_pixels フォーマットもピクセル座標がないため sgr と同一に扱う
    /// (どちらもここでは cell 座標を使う)。マウストラッキングが無効なら
    /// null を返す。
    pub fn encodeMouse(
        self: *Term,
        alloc: std.mem.Allocator,
        button: ?MouseButton,
        action: MouseAction,
        row: usize,
        col: usize,
        mods: MouseMods,
    ) !?[]u8 {
        const mouse_event = self.terminal.flags.mouse_event;
        switch (mouse_event) {
            .none => return null,
            // X10 は press のみ、かつ left/right/middle のみ報告する。
            .x10 => if (action != .press or
                button == null or
                !(button.? == .left or button.? == .right or button.? == .middle))
                return null,
            // normal (1000) は motion を報告しない。
            .normal => if (action == .motion) return null,
            // button-event (1002) はボタンを押している間の motion のみ。
            .button => if (button == null) return null,
            .any => {},
        }

        const button_code: u8 = code: {
            var acc: u8 = 0;
            if (button == null) {
                // ボタンなしの motion (any モードのみここに来る)。
                acc = 3;
            } else if (action == .release and
                self.terminal.flags.mouse_format != .sgr and
                self.terminal.flags.mouse_format != .sgr_pixels)
            {
                // SGR 系以外は release を区別できないので button 3 固定。
                acc = 3;
            } else {
                acc = switch (button.?) {
                    .left => 0,
                    .middle => 1,
                    .right => 2,
                    .wheel_up => 64,
                    .wheel_down => 65,
                    .wheel_left => 66,
                    .wheel_right => 67,
                };
            }

            // X10 は修飾キーを表現できない。
            if (mouse_event != .x10) {
                if (mods.shift) acc += 4;
                if (mods.alt) acc += 8;
                if (mods.ctrl) acc += 16;
            }

            if (action == .motion) acc += 32;
            break :code acc;
        };

        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        const w = &aw.writer;

        switch (self.terminal.flags.mouse_format) {
            .x10 => {
                // 32 を足した値を1バイトにそのまま詰める方式なので、
                // 223 (255-32) を超える座標はエンコードできない。
                if (col > 222 or row > 222) {
                    aw.deinit();
                    return null;
                }
                try w.writeAll("\x1b[M");
                try w.writeByte(32 + button_code);
                try w.writeByte(@intCast(32 + col + 1));
                try w.writeByte(@intCast(32 + row + 1));
            },
            .utf8 => {
                try w.writeAll("\x1b[M");
                try w.writeByte(32 + button_code);
                try writeUtf8Coord(w, col);
                try writeUtf8Coord(w, row);
            },
            .sgr, .sgr_pixels => {
                const final: u8 = if (action == .release) 'm' else 'M';
                try w.print("\x1b[<{d};{d};{d}{c}", .{ button_code, col + 1, row + 1, final });
            },
            .urxvt => {
                try w.print("\x1b[{d};{d};{d}M", .{ 32 + button_code, col + 1, row + 1 });
            },
        }

        return try aw.toOwnedSlice();
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
            // RenderState の行 dirty フラグは「ハンドリングした側が false に
            // 戻す」契約 (ghostty render.zig の doc コメント)。戻さないと
            // 一度 dirty になった行が以後の全 feed で再送され続ける。
            row_dirty[y] = false;
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

test "変更のない feed は dirty を返さない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 5);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "ab");
        defer update.deinit();
        try testing.expect(update.dirty.len > 0);
    }

    {
        var update = try t.feed(alloc, "");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 0), update.dirty.len);
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

test "encodeMouse はトラッキング無効なら null を返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 1, 2, .{});
    try testing.expectEqual(@as(?[]u8, null), bytes);
}

test "encodeMouse はモード1000+1006でSGR形式のpress/releaseをエンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1006h");
        defer update.deinit();
    }

    {
        const bytes = try t.encodeMouse(alloc, .left, .press, 1, 2, .{});
        defer if (bytes) |b| alloc.free(b);
        // 0-origin (row=1, col=2) -> 1-origin (col+1=3, row+1=2)。
        try testing.expectEqualStrings("\x1b[<0;3;2M", bytes.?);
    }

    {
        const bytes = try t.encodeMouse(alloc, .left, .release, 1, 2, .{});
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1b[<0;3;2m", bytes.?);
    }
}

test "encodeMouse はSGRモードで修飾キーをビット加算する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1006h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 0, 0, .{ .ctrl = true, .shift = true });
    defer if (bytes) |b| alloc.free(b);
    // button 0 + shift(4) + ctrl(16) = 20。
    try testing.expectEqualStrings("\x1b[<20;1;1M", bytes.?);
}

test "encodeMouse はモード1002 (button)ではボタンなしのmotionをnullにする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1002h\x1b[?1006h");
    defer update.deinit();

    {
        const bytes = try t.encodeMouse(alloc, null, .motion, 1, 1, .{});
        try testing.expectEqual(@as(?[]u8, null), bytes);
    }

    {
        const bytes = try t.encodeMouse(alloc, .left, .motion, 1, 1, .{});
        defer if (bytes) |b| alloc.free(b);
        try testing.expect(bytes != null);
    }
}

test "encodeMouse はホイールをボタン64/65としてエンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1006h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .wheel_up, .press, 0, 0, .{});
    defer if (bytes) |b| alloc.free(b);
    try testing.expectEqualStrings("\x1b[<64;1;1M", bytes.?);
}

test "encodeMouse はモード1000 (normal)ではmotionをnullにする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1006h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .motion, 1, 1, .{});
    try testing.expectEqual(@as(?[]u8, null), bytes);
}

test "encodeMouse はx10形式でバイト直値エンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // mode 9 (X10) はデフォルトの x10 フォーマットのままトラッキングだけ有効にする。
    var update = try t.feed(alloc, "\x1b[?9h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 1, 2, .{});
    defer if (bytes) |b| alloc.free(b);
    // ESC [ M (32+button) (32+col+1) (32+row+1)。
    try testing.expectEqualStrings(&[_]u8{ 0x1b, '[', 'M', 32, 32 + 3, 32 + 2 }, bytes.?);
}
