const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const handler = @import("handler.zig");
const row_mod = @import("row.zig");
const style = @import("style.zig");
const relay = @import("relay.zig");
const clipboard = @import("clipboard.zig");

pub const Color = style.Color;
pub const Underline = style.Underline;
pub const Style = style.Style;
pub const Span = style.Span;
pub const StyleId = style.StyleId;

/// history (scrollback) の上限を無制限 (null) にする値。ghostty の既定
/// 10_000 バイトでは 80 桁で 2 ページ程度しか持てず、1 回の feed や
/// resize で積まれた行が buildUpdate に届く前に PageList.grow の枝刈り
/// で捨てられて、確定テキストからまとまって欠落していた (M-14)。
///
/// buildUpdate は毎回 history を全部取り出して eraseDisplay(.scrollback)
/// するため、ここを無制限にしても常駐量が増え続けることはない。ピークは
/// 「1 回の feed / resize が積む行数」に比例するだけで、Emacs へ渡した
/// 時点でページは解放される。
const unlimited_scrollback: ?usize = null;

/// スタイルテーブルの既定の上限。truecolor を細かく変える出力
/// (グラデーション等) は理屈上いくらでも新しいスタイルを作れるので、
/// 上限を超えたら ID を振り直して全行を送り直す。Emacs 側のキャッシュも
/// 道連れに捨てさせる。
const default_style_limit = 4096;

/// UTF-8 マウス報告 (mode 1005) の1座標分。32 (SP) + 1-origin 変換込みの
/// コードポイントを直接 UTF-8 で書く (xterm の実装に合わせて西暦2000年
/// 問題ならぬ「座標223超えでバイトが衝突する」x10 形式の限界を回避する)。
fn writeUtf8Coord(w: *std.Io.Writer, coord: usize) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(@intCast(32 + coord + 1), &buf);
    try w.writeAll(buf[0..n]);
}

/// mode 1005 の座標はコードポイントとして UTF-8 化されるため、変換後の
/// 値がサロゲート域 (U+D800-U+DFFF) に入る座標はエンコード不能。
/// utf8Encode のエラーで encode-mouse 全体を落とすのではなく、x10 の
/// 座標 222 超過と同じく「報告なし」として扱うための事前判定。
fn utf8CoordEncodable(coord: usize) bool {
    const cp = 32 + coord + 1;
    return cp < 0xd800 or cp > 0xdfff;
}

/// scrolled_off の各行。Row と DirtyRow で所有権の解放ロジックが重複するが、
/// DirtyRow は行番号を持つため型を分けている。
pub const Row = row_mod.Extracted;

pub const DirtyRow = struct {
    row: usize,
    text: []u8,
    spans: []Span,
    cells: ?[]u8,

    pub fn deinit(self: *DirtyRow, alloc: std.mem.Allocator) void {
        for (self.spans) |*s| s.deinit(alloc);
        alloc.free(self.spans);
        alloc.free(self.text);
        if (self.cells) |c| alloc.free(c);
        self.* = undefined;
    }
};

pub const Cursor = struct {
    row: usize,
    col: usize,
    /// col に対応する、その行の text 内のコードポイント index。
    /// Emacs 側が char-width の和でセル列を解決すると、ghostty と
    /// Emacs で幅の数え方が違う文字 (国旗など) でずれるため、モジュール
    /// 側で数えた値を一緒に渡す。
    index: usize,
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
    /// 描画とは別に外側の端末へ中継するもの。mode 2026 の中でも保留しない。
    relay: []relay.Event,
    /// 子のクリップボード操作。Elisp が feed の後に処理する。mode 2026 の
    /// 中でも保留しない。
    clipboard: []clipboard.Request,
    /// この update で初出のスタイル。ID は styles_first_id からの連番。
    /// Term のテーブルからの借用 (Term の方が長生きする) なので解放しない。
    styles: []const Style,
    styles_first_id: StyleId,
    /// 真なら受け手は覚えている ID をすべて捨てる (テーブルを振り直した)。
    styles_reset: bool,
    /// 真なら mode 2026 の中で feed が終わったため描画を保留している。
    /// responses 以外は空で、保留した変更は次に描く update にまとめて載る。
    synchronized: bool = false,
    /// 子がフォーカスの報告 (mode 1004) を求めているか。描画ではないので
    /// mode 2026 の中でも今の値を載せる。
    focus_event: bool,

    pub fn deinit(self: *Update) void {
        for (self.dirty) |*d| d.deinit(self.alloc);
        self.alloc.free(self.dirty);
        for (self.scrolled_off) |*r| r.deinit(self.alloc);
        self.alloc.free(self.scrolled_off);
        self.alloc.free(self.responses);
        if (self.title) |t| self.alloc.free(t);
        relay.deinitAll(self.alloc, self.relay);
        clipboard.deinitAll(self.alloc, self.clipboard);
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
    pending_relay: std.ArrayList(relay.Event) = .empty,
    clipboard: clipboard.State = .{},
    color_scheme: ?handler.ColorScheme = null,
    colors: handler.Colors = .{},
    in_alt_screen: bool = false,
    styles: style.Table,
    /// テストから小さい値にできるよう Term のフィールドにしている。
    style_limit: usize = default_style_limit,

    pub fn init(alloc: std.mem.Allocator, rows: u16, cols: u16) !*Term {
        const self = try alloc.create(Term);
        errdefer alloc.destroy(self);

        self.* = .{
            .alloc = alloc,
            .terminal = try .init(ghostty_vt.TinyIo.init.io(), alloc, .{
                .rows = rows,
                .cols = cols,
                .max_scrollback_bytes = unlimited_scrollback,
                // Ghostty アプリ (termio/Termio.zig) と同じ既定。modes.set で
                // 立てるだけだと RIS で無効に戻ってしまう。
                .default_modes = .{ .grapheme_cluster = true },
            }),
            .stream = undefined,
            .styles = .init(alloc),
        };
        self.stream = .init(.{
            .allocator = alloc,
            .handler = .init(
                &self.terminal,
                alloc,
                &self.responses,
                &self.pending_title,
                &self.pending_relay,
                &self.clipboard,
                &self.color_scheme,
                &self.colors,
            ),
        });

        return self;
    }

    pub fn deinit(self: *Term) void {
        const alloc = self.alloc;
        self.stream.deinit();
        self.styles.deinit();
        self.render.deinit(alloc);
        self.terminal.deinit(alloc);
        self.responses.deinit(alloc);
        if (self.pending_title) |t| alloc.free(t);
        for (self.pending_relay.items) |*e| e.deinit(alloc);
        self.pending_relay.deinit(alloc);
        self.clipboard.deinit(alloc);
        self.* = undefined;
        alloc.destroy(self);
    }

    /// PTY からのバイト列を1つの状態機械に食わせる。エスケープシーケンスが
    /// 複数回の feed に跨って分割される可能性があるため、Parser の状態は
    /// self.stream に永続化してあり、呼び出しごとに作り直さない。
    pub fn feed(self: *Term, alloc: std.mem.Allocator, bytes: []const u8) !Update {
        try self.feedWithoutDel(bytes);
        if (self.terminal.modes.get(.synchronized_output)) return self.deferredUpdate(alloc);
        return self.buildUpdate(alloc);
    }

    /// mode 2026 を解除して描く。アプリが mode 2026 を閉じないまま
    /// 止まったときに、呼び出し側のタイムアウトから使う。
    pub fn flush(self: *Term, alloc: std.mem.Allocator) !Update {
        self.terminal.modes.set(.synchronized_output, false);
        return self.buildUpdate(alloc);
    }

    /// buildUpdate を通らないので、dirty フラグも scrollback も消費されず
    /// 次の buildUpdate にそのまま残る。
    fn deferredUpdate(self: *Term, alloc: std.mem.Allocator) !Update {
        const relay_events = try relay.take(&self.pending_relay, self.alloc, alloc);
        errdefer relay.deinitAll(alloc, relay_events);
        const clipboard_requests = try self.clipboard.take(self.alloc, alloc);
        errdefer clipboard.deinitAll(alloc, clipboard_requests);
        return .{
            .alloc = alloc,
            .dirty = &.{},
            .scrolled_off = &.{},
            .cursor = .{ .row = 0, .col = 0, .index = 0, .visible = false },
            .responses = try self.takeResponses(alloc),
            .relay = relay_events,
            .clipboard = clipboard_requests,
            .alt_screen = .unchanged,
            .styles = &.{},
            .styles_first_id = @intCast(self.styles.count()),
            .styles_reset = false,
            .title = null,
            .synchronized = true,
            .focus_event = self.terminal.modes.get(.focus_event),
        };
    }

    fn takeResponses(self: *Term, alloc: std.mem.Allocator) ![]u8 {
        const responses = try alloc.dupe(u8, self.responses.items);
        self.responses.clearRetainingCapacity();
        return responses;
    }

    /// DEL (0x7F) を落としてからパーサへ渡す。ECMA-48 では DEL は常に
    /// 無視される制御文字だが、ghostty はセルに格納するため、Emacs 側
    /// では 1 セルが =^?= の 2 桁で描かれてセル列と表示桁がずれる。
    /// 0x7F は UTF-8 の多バイト列の内側には現れないので、バイト単位で
    /// 切り出しても文字は壊れない。パーサの状態は feed をまたいで
    /// self.stream に残るため、分割して渡しても解釈は変わらない。
    fn feedWithoutDel(self: *Term, bytes: []const u8) !void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, 0x7f)) |i| {
            if (i > 0) try self.nextSlice(rest[0..i]);
            rest = rest[i + 1 ..];
        }
        try self.nextSlice(rest);
    }

    fn nextSlice(self: *Term, bytes: []const u8) !void {
        self.stream.nextSlice(bytes);
        if (self.stream.handler.takeFailure()) |err| return err;
    }

    /// 子が明暗の変化の通知 (mode 2031) を求めていて、明暗が変わったときは
    /// 子へ送る通知を返す。
    pub fn setColorScheme(self: *Term, scheme: handler.ColorScheme) ?[]const u8 {
        const changed = if (self.color_scheme) |old| old != scheme else true;
        self.color_scheme = scheme;
        if (!changed or !self.terminal.modes.get(.report_color_scheme)) return null;
        return scheme.report();
    }

    /// 子が可視性の変化の通知 (mode 2033) を求めていて、可視性が変わった
    /// ときは子へ送る通知を返す。渡す前は、Ghostty と同じく見えている
    /// として扱う。
    pub fn setVisibility(self: *Term, visible: bool) ?[]const u8 {
        const changed = self.terminal.flags.visible != visible;
        self.terminal.flags.visible = visible;
        if (!changed or !self.terminal.modes.get(.report_visibility)) return null;
        return handler.visibilityReport(visible);
    }

    /// 子のクリップボードの要求 ID に DATA で答えるバイト列を返す。
    /// DATA が null なら断り、REMEMBER なら要求のパスワードを覚える。答える
    /// バイト列が無ければ null。
    pub fn clipboardReply(self: *Term, alloc: std.mem.Allocator, id: u64, data: ?[]const u8, remember: bool) !?[]u8 {
        return self.clipboard.reply(self.alloc, alloc, &self.stream.handler.inner.kitty_clipboard_grants, id, data, remember);
    }

    pub fn setClipboardWrite(self: *Term, policy: clipboard.WritePolicy) void {
        self.clipboard.write_policy = policy;
    }

    /// mode 5522 の間の貼り付けで、本文の代わりに送る paste イベント。
    /// mode 5522 でなければ null。
    pub fn encodePasteEvent(self: *Term, alloc: std.mem.Allocator) !?[]u8 {
        return clipboard.pasteEvent(&self.terminal, &self.stream.handler.inner.kitty_clipboard_grants, self.alloc, alloc);
    }

    pub fn setColors(self: *Term, colors: handler.Colors) void {
        self.colors = colors;
    }

    pub fn resize(self: *Term, alloc: std.mem.Allocator, rows: u16, cols: u16) !Update {
        try self.terminal.resize(self.alloc, .{ .cols = cols, .rows = rows });
        // ghostty 本体も resize で mode 2026 を解除する (termio/Termio.zig)。
        // 保留したままだと、新しいサイズで描き直す機会がアプリ次第になる。
        self.terminal.modes.set(.synchronized_output, false);
        return self.buildUpdate(alloc);
    }

    pub fn encodeKey(self: *Term, alloc: std.mem.Allocator, event: ghostty_vt.input.KeyEvent) !?[]u8 {
        var opts = ghostty_vt.input.KeyEncodeOptions.fromTerminal(&self.terminal);
        // .false にしない: darwin ビルドの key encoder は comptime 分岐で
        // この値を見て alt 修飾を捨て (Option を文字合成に回す macOS の
        // 慣習に合わせるため)、alt+a が ESC 前置なしの "a" になる。ここに
        // 届く alt は Emacs が meta と解決済みのもので、物理キーの Option
        // かどうかは既に問題にならない。
        opts.macos_option_as_alt = .true;

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
                if (!utf8CoordEncodable(col) or !utf8CoordEncodable(row)) {
                    aw.deinit();
                    return null;
                }
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
        // 振り直しは行の抽出を始める前に済ませる。抽出の途中で振り直すと
        // 1 つの update に新旧の ID が混ざる。
        const styles_reset = self.styles.count() > self.style_limit;
        if (styles_reset) self.styles.clear();
        const styles_mark = self.styles.count();

        const alt_screen: AltScreen = alt: {
            const now_alt = self.terminal.screens.active_key == .alternate;
            defer self.in_alt_screen = now_alt;
            if (now_alt == self.in_alt_screen) break :alt .unchanged;
            break :alt if (now_alt) .entered else .left;
        };

        // alternate screen は max_scrollback_bytes=0 で初期化されるため
        // (ghostty Terminal.switchScreen)、active が primary のときだけ見ればよい。
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
                var extracted = try row_mod.extractRow(alloc, pin, &self.styles);
                errdefer extracted.deinit(alloc);
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
            // ID を振り直した回は、画面に残っている行が Emacs 側から見て
            // 未知の ID を指したままになるので、全行を送り直す。
            if (!row_dirty[y] and !styles_reset) continue;
            var extracted = try row_mod.extractRow(alloc, row_pins[y], &self.styles);
            errdefer extracted.deinit(alloc);
            try dirty.append(alloc, .{
                .row = y,
                .text = extracted.text,
                .spans = extracted.spans,
                .cells = extracted.cells,
            });
            // RenderState の行 dirty フラグは「ハンドリングした側が false に
            // 戻す」契約 (ghostty render.zig の doc コメント)。戻さないと
            // 一度 dirty になった行が以後の全 feed で再送され続ける。
            row_dirty[y] = false;
        }

        const screen_cursor = &self.terminal.screens.active.cursor;
        const cursor: Cursor = .{
            .row = self.render.cursor.active.y,
            .col = self.render.cursor.active.x,
            .index = row_mod.cellToIndex(screen_cursor.page_pin.*, screen_cursor.x),
            .visible = self.render.cursor.visible,
        };

        const responses = try self.takeResponses(alloc);
        errdefer alloc.free(responses);

        const relay_events = try relay.take(&self.pending_relay, self.alloc, alloc);
        errdefer relay.deinitAll(alloc, relay_events);

        const clipboard_requests = try self.clipboard.take(self.alloc, alloc);
        errdefer clipboard.deinitAll(alloc, clipboard_requests);

        var title: ?[]u8 = null;
        errdefer if (title) |t| alloc.free(t);
        if (self.pending_title) |t| {
            title = try alloc.dupe(u8, t);
            self.alloc.free(t);
            self.pending_title = null;
        }

        // toOwnedSlice 後は ArrayList 側の errdefer が空リストしか守らない
        // ので、owned slice 自身にも errdefer を張ってから次の失敗しうる
        // 呼び出しへ進む (arena 以外のアロケータでのリーク防止)。
        const dirty_slice = try dirty.toOwnedSlice(alloc);
        errdefer {
            for (dirty_slice) |*d| d.deinit(alloc);
            alloc.free(dirty_slice);
        }
        const scrolled_off_slice = try scrolled_off.toOwnedSlice(alloc);

        return .{
            .alloc = alloc,
            .dirty = dirty_slice,
            .scrolled_off = scrolled_off_slice,
            .cursor = cursor,
            .responses = responses,
            .relay = relay_events,
            .clipboard = clipboard_requests,
            .alt_screen = alt_screen,
            .styles = self.styles.since(styles_mark),
            .styles_first_id = @intCast(styles_mark),
            .styles_reset = styles_reset,
            .title = title,
            .focus_event = self.terminal.modes.get(.focus_event),
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
    try testing.expect(Color.eql(t.styles.get(span.id).fg, .{ .palette = 1 }));
}

test "feed は 256色の span を抽出する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[38;5;208mHi");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(Color.eql(t.styles.get(update.dirty[0].spans[0].id).fg, .{ .palette = 208 }));
}

test "feed は 24bit色の span を抽出する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[38;2;10;20;30mHi");
    defer update.deinit();

    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(Color.eql(
        t.styles.get(update.dirty[0].spans[0].id).fg,
        .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
    ));
}

test "feed 境界で分割されたエスケープシーケンスも解釈される" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[3");
        defer update.deinit();
    }

    var update = try t.feed(alloc, "1mHi");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(Color.eql(t.styles.get(update.dirty[0].spans[0].id).fg, .{ .palette = 1 }));
}

test "feed 境界で分割された UTF-8 多バイト文字も描画される" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    // "あ" (0xE3 0x81 0x82) を 1 バイト目とそれ以降に分割して食わせる。
    {
        var update = try t.feed(alloc, "\xe3");
        defer update.deinit();
    }

    var update = try t.feed(alloc, "\x81\x82!");
    defer update.deinit();
    try testing.expectEqualStrings("あ!       ", update.dirty[0].text);
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

test "buildUpdate は途中の割り当て失敗でもリークしない" {
    const S = struct {
        fn run(alloc: std.mem.Allocator) !void {
            // Term 自体は安定したアロケータに置き、Update 構築用の alloc
            // だけに失敗を注入する (モジュール経由の arena に相当する側)。
            const t = try Term.init(testing.allocator, 2, 5);
            defer t.deinit();
            var update = try t.feed(alloc, "\x1b]2;hi\x07\x1b[6n1\r\n2\r\n3\r\n");
            update.deinit();
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, S.run, .{});
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

test "dirty と scrolled_off の行は書記素ごとのセル数を持つ" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 4);
    defer t.deinit();

    // 既定で mode 2027 が有効なので、国旗は 1 書記素 2 セル。
    var update = try t.feed(alloc, "\u{6F22}a\r\n\u{1F1EF}\u{1F1F5}a");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 1), update.scrolled_off.len);
    try testing.expectEqualSlices(u8, &.{ 2, 1, 1 }, update.scrolled_off[0].cells.?);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 1, 1 }, update.dirty[0].cells.?);
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

test "mode 2026 の中で終わった feed は描画を保留し、閉じた feed でまとめて返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "abc");
        defer update.deinit();
    }

    {
        var update = try t.feed(alloc, "\x1b[?2026h\x1b[2K\r");
        defer update.deinit();
        try testing.expect(update.synchronized);
        try testing.expectEqual(@as(usize, 0), update.dirty.len);
    }

    var update = try t.feed(alloc, "XY\x1b[?2026l");
    defer update.deinit();
    try testing.expect(!update.synchronized);
    try testing.expectEqual(@as(usize, 1), update.dirty.len);
    try testing.expectEqualStrings("XY        ", update.dirty[0].text);
}

test "保留中にスクロールアウトした行は閉じた feed で返る" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 5);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[?2026h1\r\n2\r\n3\r\n4\r\n");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 0), update.scrolled_off.len);
    }

    var update = try t.feed(alloc, "\x1b[?2026l");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 2), update.scrolled_off.len);
    try testing.expectEqualStrings("1    ", update.scrolled_off[0].text);
    try testing.expectEqualStrings("2    ", update.scrolled_off[1].text);
}

test "保留中も端末への応答は返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?2026h\x1b[6n");
    defer update.deinit();
    try testing.expect(update.synchronized);
    try testing.expectEqualStrings("\x1b[1;1R", update.responses);
}

test "flush は mode 2026 を解除して描く" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[?2026hab");
        defer update.deinit();
        try testing.expect(update.synchronized);
    }

    {
        var update = try t.flush(alloc);
        defer update.deinit();
        try testing.expect(!update.synchronized);
        try testing.expectEqualStrings("ab        ", update.dirty[0].text);
    }

    var update = try t.feed(alloc, "c");
    defer update.deinit();
    try testing.expect(!update.synchronized);
    try testing.expectEqualStrings("abc       ", update.dirty[0].text);
}

test "resize は mode 2026 を解除して描く" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[?2026hab");
        defer update.deinit();
    }

    {
        var update = try t.resize(alloc, 1, 12);
        defer update.deinit();
        try testing.expect(!update.synchronized);
        try testing.expectEqualStrings("ab          ", update.dirty[0].text);
    }

    var update = try t.feed(alloc, "c");
    defer update.deinit();
    try testing.expect(!update.synchronized);
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

test "DSR は DECOM 有効時にスクロール領域相対のカーソル位置で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // 行 3-5 をスクロール領域にして DECOM を有効化すると、カーソルは
    // 領域左上 (絶対では行3) に移る。応答は領域相対の 1;1 であるべきで、
    // 絶対座標の 3;1 を返してはならない。
    var update = try t.feed(alloc, "\x1b[3;5r\x1b[?6h\x1b[6n");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[1;1R", update.responses);
}

test "DECRQM は既知モードの現在値で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // DECTCEM (?25) は既定で有効なので 1 (set)、synchronized output
    // (?2026) は未設定なので 2 (reset)。
    var update = try t.feed(alloc, "\x1b[?25$p\x1b[?2026$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?25;1$y\x1b[?2026;2$y", update.responses);
}

test "書記素クラスタ (?2027) は既定で有効で、RIS で既定に戻る" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?2027$p\x1b[?2027l\x1b[?2027$p\x1bc\x1b[?2027$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?2027;1$y\x1b[?2027;2$y\x1b[?2027;1$y", update.responses);
}

test "ANSI 形式の DECRQM (CSI Ps $ p) は ? なしの DECRPM で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[4h\x1b[4$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[4;1$y", update.responses);
}

test "DECRQM は未知のモードに 0 (認識せず) で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?9999$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?9999;0$y", update.responses);
}

test "DECRQM は SGR pixel 座標 (?1016) に設定の前後とも 0 (未対応) で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1016$p\x1b[?1016h\x1b[?1016$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?1016;0$y\x1b[?1016;0$y", update.responses);
}

test "DECRQM は kitty の paste イベント (?5522) の現在値を 1 / 2 で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?5522$p\x1b[?5522h\x1b[?5522$p");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?5522;2$y\x1b[?5522;1$y", update.responses);
}

test "DECRQM は可視性の報告 (?2033) の現在値を 1 / 2 で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var before = try t.feed(alloc, "\x1b[?2033$p");
    defer before.deinit();
    try testing.expectEqualStrings("\x1b[?2033;2$y", before.responses);
    var after = try t.feed(alloc, "\x1b[?2033h\x1b[?2033$p");
    defer after.deinit();
    try testing.expectEqualStrings("\x1b[?999;1n\x1b[?2033;1$y", after.responses);
}

test "DECXCPR (CSI ? 6 n) はページ番号 1 を添えた位置で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[3;4H\x1b[?6n");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?3;4;1R", update.responses);
}

test "DECXCPR (CSI ? 6 n) は origin mode でスクロール領域からの相対位置で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[2;4r\x1b[?6h\x1b[2;3H\x1b[?6n");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?2;3;1R", update.responses);
}

test "CSI ? 998 n は渡された可視性で応答し、渡す前は見えているとして答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var before = try t.feed(alloc, "\x1b[?998n");
    defer before.deinit();
    try testing.expectEqualStrings("\x1b[?999;1n", before.responses);
    _ = t.setVisibility(false);
    var hidden = try t.feed(alloc, "\x1b[?998n");
    defer hidden.deinit();
    try testing.expectEqualStrings("\x1b[?999;2n", hidden.responses);
    _ = t.setVisibility(true);
    var shown = try t.feed(alloc, "\x1b[?998n");
    defer shown.deinit();
    try testing.expectEqualStrings("\x1b[?999;1n", shown.responses);
}

test "mode 2033 を立てた時点で今の可視性を送る" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    _ = t.setVisibility(false);
    var update = try t.feed(alloc, "\x1b[?2033h\x1b[?2033h\x1b[?2033l\x1b[?2033l");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?999;2n\x1b[?999;2n", update.responses);
}

test "setVisibility は mode 2033 の間に可視性が変わったときだけ通知を返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    try testing.expectEqual(@as(?[]const u8, null), t.setVisibility(false));
    try testing.expectEqual(@as(?[]const u8, null), t.setVisibility(true));
    var update = try t.feed(alloc, "\x1b[?2033h");
    defer update.deinit();
    try testing.expectEqual(@as(?[]const u8, null), t.setVisibility(true));
    try testing.expectEqualStrings("\x1b[?999;2n", t.setVisibility(false).?);
    try testing.expectEqual(@as(?[]const u8, null), t.setVisibility(false));
    try testing.expectEqualStrings("\x1b[?999;1n", t.setVisibility(true).?);
}

test "APC の kitty graphics と glyph protocol は読み捨て、続く文字は描く" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(
        alloc,
        "\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\" ++
            "\x1b_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1b\\ab",
    );
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
    try testing.expectEqualStrings("ab        ", update.dirty[0].text);
    try testing.expectEqual(0, @sizeOf(@TypeOf(t.terminal.screens.active.kitty_images)));
    try testing.expect(!t.terminal.glyph_glossary.contains(0xE0A0));
}

test "feed は端末状態の更新や応答の組み立てで確保に失敗したら OutOfMemory を返す" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const t = try Term.init(failing.allocator(), 1, 10);
    defer t.deinit();

    // OSC 8 のハイパーリンクは Terminal 側、OSC 2 のタイトルは Handler
    // 側で確保する。
    for ([_][]const u8{ "\x1b]8;;http://a\x1b\\x", "\x1b]2;hi\x07" }) |bytes| {
        failing.fail_index = failing.alloc_index;
        try testing.expectError(error.OutOfMemory, t.feed(testing.allocator, bytes));
        failing.fail_index = std.math.maxInt(usize);
    }
}

test "XTVERSION は同梱する ghostty の版で Ghostty と同じ形で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[>q\x1b[>0q");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1bP>|ghostty 1.4.0\x1b\\\x1bP>|ghostty 1.4.0\x1b\\",
        update.responses,
    );
}

test "kitty keyboard query (CSI ? u) は現在の flags で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // 既定はフラグなしの 0、push (CSI > 1 u) 後はスタック先頭の 1。
    var update = try t.feed(alloc, "\x1b[?u\x1b[>1u\x1b[?u");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?0u\x1b[?1u", update.responses);
}

test "XTGETTCAP は同梱 terminfo の値で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // "Co" (436F) の値は 256 (323536)。応答は ghostty 本体と同じく
    // DCS 1 + r <hex key>=<hex value> ST。
    var update = try t.feed(alloc, "\x1bP+q436F\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings("\x1bP1+r436F=323536\x1b\\", update.responses);
}

test "XTGETTCAP は未知のキーに応答しない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // "zz" (7A7A) は terminfo に無いので、ghostty 本体同様に無応答。
    var update = try t.feed(alloc, "\x1bP+q7A7A\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
}

test "XTGETTCAP は ; 区切りの複数キーに順に応答し未知キーだけ飛ばす" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    // Co (436F) -> 256、zz (7A7A) は未知、RGB (524742) -> 8 (38)。
    var update = try t.feed(alloc, "\x1bP+q436F;7A7A;524742\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1bP1+r436F=323536\x1b\\\x1bP1+r524742=38\x1b\\",
        update.responses,
    );
}

test "XTGETTCAP は小文字の 16 進キーでも応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1bP+q436f\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings("\x1bP1+r436F=323536\x1b\\", update.responses);
}

test "ST の来ない XTGETTCAP を残したまま deinit してもリークしない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1bP+q436F");
    defer update.deinit();
    try testing.expectEqualStrings("", update.responses);
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

test "OSC 777 と OSC 9 の通知は中継にタイトルと本文を積む" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]777;notify;T;a;b\x07\x1b]9;done\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 2), update.relay.len);
    try testing.expectEqualStrings("T", update.relay[0].notification.title);
    try testing.expectEqualStrings("a;b", update.relay[0].notification.body);
    try testing.expectEqualStrings("", update.relay[1].notification.title);
    try testing.expectEqualStrings("done", update.relay[1].notification.body);
}

test "OSC 9;4 の進捗は中継に状態と値を積む" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]9;4;1;50\x07\x1b]9;4;3;0\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 2), update.relay.len);
    try testing.expectEqual(relay.Progress{ .state = 1, .value = 50 }, update.relay[0].progress);
    try testing.expectEqual(relay.Progress{ .state = 3, .value = null }, update.relay[1].progress);
}

test "BEL は中継にベルを積み、OSC の終端の BEL は積まない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "a\x07\x1b]2;t\x07");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 1), update.relay.len);
    try testing.expect(update.relay[0] == .bell);
}

test "mode 2026 の中でも中継するものは保留しない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?2026h\x1b]9;done\x07");
    defer update.deinit();
    try testing.expect(update.synchronized);
    try testing.expectEqual(@as(usize, 1), update.relay.len);
}

test "中継するものを渡す前に Term を捨ててもリークしない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    try t.feedWithoutDel("\x1b]9;done\x07");
    t.deinit();
}

test "フォーカスの報告 (mode 1004) を求めているかを mode 2026 の中でも返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var off = try t.feed(alloc, "a");
    defer off.deinit();
    try testing.expect(!off.focus_event);
    var on = try t.feed(alloc, "\x1b[?1004h");
    defer on.deinit();
    try testing.expect(on.focus_event);
    var held = try t.feed(alloc, "\x1b[?2026h");
    defer held.deinit();
    try testing.expect(held.synchronized);
    try testing.expect(held.focus_event);
}

test "明暗の問い合わせには渡された明暗で答え、渡される前は答えない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var before = try t.feed(alloc, "\x1b[?996n");
    defer before.deinit();
    try testing.expectEqualStrings("", before.responses);
    _ = t.setColorScheme(.light);
    var after = try t.feed(alloc, "\x1b[?996n");
    defer after.deinit();
    try testing.expectEqualStrings("\x1b[?997;2n", after.responses);
}

test "setColorScheme は mode 2031 の間に明暗が変わったときだけ通知を返す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    try testing.expectEqual(@as(?[]const u8, null), t.setColorScheme(.dark));
    try testing.expectEqual(@as(?[]const u8, null), t.setColorScheme(.light));
    var update = try t.feed(alloc, "\x1b[?2031h");
    defer update.deinit();
    try testing.expectEqual(@as(?[]const u8, null), t.setColorScheme(.light));
    try testing.expectEqualStrings("\x1b[?997;1n", t.setColorScheme(.dark).?);
}

test "色の問い合わせには渡された色で、問い合わせと同じ終端で答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var colors: handler.Colors = .{
        .foreground = .{ .r = 0xffff, .g = 0xeeee, .b = 0x0102 },
        .background = .{ .r = 0, .g = 0x1010, .b = 0x2020 },
    };
    colors.palette[1] = .{ .r = 0xcdcd, .g = 0, .b = 0 };
    colors.palette[2] = .{ .r = 0, .g = 0xcdcd, .b = 0 };
    t.setColors(colors);
    var update = try t.feed(alloc, "\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]4;1;?;2;?\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]10;rgb:ffff/eeee/0102\x07" ++
            "\x1b]11;rgb:0000/1010/2020\x1b\\" ++
            "\x1b]4;1;rgb:cdcd/0000/0000\x1b\\" ++
            "\x1b]4;2;rgb:0000/cdcd/0000\x1b\\",
        update.responses,
    );
}

test "OSC 10 に続けて ? を並べると、前景・背景の順に答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    t.setColors(.{
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .background = .{ .r = 4, .g = 5, .b = 6 },
    });
    var update = try t.feed(alloc, "\x1b]10;?;?\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]10;rgb:0001/0002/0003\x1b\\\x1b]11;rgb:0004/0005/0006\x1b\\",
        update.responses,
    );
}

test "渡されていない色と OSC 12 には答えず、続く問い合わせには答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    t.setColors(.{ .foreground = .{ .r = 1, .g = 2, .b = 3 } });
    var update = try t.feed(alloc, "\x1b]11;?\x1b\\\x1b]4;1;?\x1b\\\x1b]12;?\x1b\\\x1b[c");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?62;22;52c", update.responses);
}

test "16〜255 の問い合わせには、子が設定しても xterm パレットの値で答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b]4;196;rgb:00/00/ff\x1b\\\x1b]4;196;?;232;?\x07");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]4;196;rgb:ffff/0000/0000\x07\x1b]4;232;rgb:0808/0808/0808\x07",
        update.responses,
    );
}

test "子が 0〜15 や既定の色を設定しても、渡された色で答える" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var colors: handler.Colors = .{ .background = .{ .r = 0, .g = 0, .b = 0 } };
    colors.palette[1] = .{ .r = 0xcdcd, .g = 0, .b = 0 };
    t.setColors(colors);
    var update = try t.feed(alloc, "\x1b]11;#ffffff\x1b\\\x1b]4;1;#00ff00\x1b\\\x1b]11;?\x1b\\\x1b]4;1;?\x1b\\");
    defer update.deinit();
    try testing.expectEqualStrings(
        "\x1b]11;rgb:0000/0000/0000\x1b\\\x1b]4;1;rgb:cdcd/0000/0000\x1b\\",
        update.responses,
    );
}

test "DA1 は Ghostty と同じく 52 を含む" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[c");
    defer update.deinit();
    try testing.expectEqualStrings("\x1b[?62;22;52c", update.responses);
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

test "encodeKey は DECBKM (?67) の on/off で Backspace を DEL と BS に切り替え、DECRQM に現在値で応答する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        const bytes = try t.encodeKey(alloc, .{ .key = .backspace });
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x7f", bytes.?);
    }

    {
        var update = try t.feed(alloc, "\x1b[?67$p\x1b[?67h\x1b[?67$p");
        defer update.deinit();
        try testing.expectEqualStrings("\x1b[?67;2$y\x1b[?67;1$y", update.responses);
    }

    {
        const bytes = try t.encodeKey(alloc, .{ .key = .backspace });
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x08", bytes.?);
    }
}

test "encodeKey は alt 付きの文字を ESC 前置でエンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    const keymap = @import("keymap.zig");
    const bytes = try t.encodeKey(alloc, keymap.charEvent('a', "a", .{ .alt = true }));
    defer if (bytes) |b| alloc.free(b);
    try testing.expectEqualStrings("\x1ba", bytes.?);
}

test "encodeKey は kitty keyboard 有効時も Shift の英大文字を平文で送り C-S-a は区別する" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[>5u");
        defer update.deinit();
    }

    const keymap = @import("keymap.zig");
    {
        const bytes = try t.encodeKey(alloc, keymap.charEvent('A', "A", .{ .shift = true }));
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("A", bytes.?);
    }
    {
        const bytes = try t.encodeKey(alloc, keymap.charEvent('a', "a", .{ .ctrl = true, .shift = true }));
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1b[97;6u", bytes.?);
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

test "encodeMouse はutf8形式 (1005) で座標をUTF-8エンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1005h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 0, 300, .{});
    defer if (bytes) |b| alloc.free(b);
    // col 300 -> コードポイント 333 (0x14D) は UTF-8 2バイト、row 0 -> 33。
    try testing.expectEqualStrings(&[_]u8{ 0x1b, '[', 'M', 32, 0xc5, 0x8d, 33 }, bytes.?);
}

test "encodeMouse はutf8形式でサロゲート域に入る座標を null にする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1005h");
    defer update.deinit();

    // 32 + 56000 + 1 = 0xDAE1 はサロゲート域でありコードポイントとして
    // UTF-8 化できない。エラーではなく「報告なし」で返す。
    const bytes = try t.encodeMouse(alloc, .left, .press, 56000, 0, .{});
    try testing.expectEqual(@as(?[]u8, null), bytes);
}

test "encodeMouse はurxvt形式 (1015) でエンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1015h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 1, 2, .{});
    defer if (bytes) |b| alloc.free(b);
    // 32 + button 0 = 32、座標は 1-origin (col+1=3, row+1=2)。
    try testing.expectEqualStrings("\x1b[32;3;2M", bytes.?);
}

test "encodeMouse は横ホイールをボタン66/67としてエンコードする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?1000h\x1b[?1006h");
    defer update.deinit();

    {
        const bytes = try t.encodeMouse(alloc, .wheel_left, .press, 0, 0, .{});
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1b[<66;1;1M", bytes.?);
    }

    {
        const bytes = try t.encodeMouse(alloc, .wheel_right, .press, 0, 0, .{});
        defer if (bytes) |b| alloc.free(b);
        try testing.expectEqualStrings("\x1b[<67;1;1M", bytes.?);
    }
}

test "encodeMouse はx10形式で座標223超をnullにする" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 5, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[?9h");
    defer update.deinit();

    const bytes = try t.encodeMouse(alloc, .left, .press, 0, 223, .{});
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

test "feed は初出のスタイルだけを styles に載せる" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    const first_id = blk: {
        var update = try t.feed(alloc, "\x1b[31mHi");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 1), update.styles.len);
        try testing.expectEqual(@as(StyleId, 0), update.styles_first_id);
        try testing.expect(!update.styles_reset);
        break :blk update.dirty[0].spans[0].id;
    };

    // 2 回目は同じスタイルなので新規登録はなく、ID だけが再利用される。
    var update = try t.feed(alloc, "\x1b[31mHo");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 0), update.styles.len);
    try testing.expectEqual(first_id, update.dirty[0].spans[0].id);
}

test "スタイルが上限を超えると ID を振り直して全行を送り直す" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 4);
    defer t.deinit();
    t.style_limit = 2;

    // 画面に同時に載る色数で上限を超えさせる (テーブルは行の抽出時に
    // 育つので、SGR を並べるだけでは増えない)。
    {
        var update = try t.feed(alloc, "\x1b[31ma\x1b[32mb\x1b[33mc");
        defer update.deinit();
        try testing.expectEqual(@as(usize, 3), update.styles.len);
        try testing.expect(!update.styles_reset);
    }

    var update = try t.feed(alloc, "");
    defer update.deinit();
    try testing.expect(update.styles_reset);
    try testing.expectEqual(@as(StyleId, 0), update.styles_first_id);
    // 振り直し回は dirty でない行も含めて全行が載る。
    try testing.expectEqual(@as(usize, 3), update.dirty.len);
}

/// 連番行の欠落を検査するテスト用ヘルパ。update から scrolled_off の
/// 行を取り出し、行末の空白を除いた 10 進整数として集める。
const SeqCollector = struct {
    alloc: std.mem.Allocator,
    nums: std.ArrayList(usize) = .empty,

    fn deinit(self: *SeqCollector) void {
        self.nums.deinit(self.alloc);
    }

    fn take(self: *SeqCollector, update: *Update) !void {
        for (update.scrolled_off) |row| {
            const trimmed = std.mem.trimEnd(u8, row.text, " ");
            if (trimmed.len == 0) continue;
            const n = std.fmt.parseInt(usize, trimmed, 10) catch continue;
            try self.nums.append(self.alloc, n);
        }
    }

    /// 集めた連番が 1 から始まり 1 ずつ増えることを主張する。
    fn expectContiguousFromOne(self: *const SeqCollector) !void {
        try testing.expect(self.nums.items.len > 0);
        for (self.nums.items, 0..) |n, i| {
            if (n != i + 1) {
                std.debug.print(
                    "行が欠落: index {d} の値が {d} (期待 {d})\n",
                    .{ i, n, i + 1 },
                );
                return error.TestExpectedEqual;
            }
        }
    }
};

fn feedLines(t: *Term, alloc: std.mem.Allocator, from: usize, to: usize, seq: *SeqCollector) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (from..to + 1) |i| try buf.print(alloc, "{d}\r\n", .{i});
    var update = try t.feed(alloc, buf.items);
    defer update.deinit();
    try seq.take(&update);
}

test "1 回の大きな feed でも先頭の行が落ちない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 21, 80);
    defer t.deinit();

    var seq: SeqCollector = .{ .alloc = alloc };
    defer seq.deinit();

    // 80 桁ではページ 1 枚が 576 行ぶんなので、既定の max_scrollback_bytes
    // (10000 バイト) では 1200 行を 1 回で流すと先頭 576 行が捨てられる。
    try feedLines(t, alloc, 1, 1200, &seq);
    try seq.expectContiguousFromOne();
}

test "高さを戻すリサイズを挟んでも確定行が落ちない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 21, 80);
    defer t.deinit();

    var seq: SeqCollector = .{ .alloc = alloc };
    defer seq.deinit();

    try feedLines(t, alloc, 1, 5000, &seq);
    {
        var update = try t.resize(alloc, 9, 80);
        defer update.deinit();
        try seq.take(&update);
    }
    try feedLines(t, alloc, 5001, 10000, &seq);
    {
        var update = try t.resize(alloc, 21, 80);
        defer update.deinit();
        try seq.take(&update);
    }
    try feedLines(t, alloc, 10001, 15000, &seq);

    try seq.expectContiguousFromOne();
}

test "history を捨てた後に再利用される行が折り返し扱いにならない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 3, 5);
    defer t.deinit();

    // 折り返す行を出してから history ごと取り出す。
    {
        var u = try t.feed(alloc, "abcdefgh\r\nZ\r\n");
        u.deinit();
    }
    // 折り返さない短い行だけを出す。
    {
        var u = try t.feed(alloc, "PP\r\nQQ\r\nRR\r\n");
        u.deinit();
    }
    // 幅を広げる = reflow。折り返しでない行が繋がってはいけない。
    var u = try t.resize(alloc, 3, 12);
    defer u.deinit();

    for (u.dirty) |d| {
        try testing.expect(std.mem.indexOf(u8, d.text, "RR") == null or
            std.mem.indexOf(u8, d.text, "QQ") == null);
    }
    try testing.expectEqualStrings("QQ          ", u.dirty[0].text);
}

test "feed は SGR 8 (隠し) を span に載せる" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "\x1b[8mHi");
    defer update.deinit();
    try testing.expectEqual(@as(usize, 1), update.dirty[0].spans.len);
    try testing.expect(update.styles[0].invisible);
}

test "DEL (0x7F) はセルに格納されない" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    var update = try t.feed(alloc, "a\x7fb");
    defer update.deinit();
    try testing.expectEqualStrings("ab        ", update.dirty[0].text);
}

test "feed 境界で切れても DEL だけが落ちる" {
    const alloc = testing.allocator;
    const t = try Term.init(alloc, 1, 10);
    defer t.deinit();

    {
        var update = try t.feed(alloc, "\x1b[3");
        update.deinit();
    }
    var update = try t.feed(alloc, "1m\x7fHi\x7f");
    defer update.deinit();
    try testing.expectEqualStrings("Hi        ", update.dirty[0].text);
}
