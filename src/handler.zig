const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const ghostty_terminfo = @import("ghostty-terminfo");

/// ReadonlyHandler は DSR/DA など応答が必要なアクションを無視する
/// (ghostty のドキュメント通り、応答不要な再生専用ユースケース向けのため)。
/// PTY への応答を組み立てる必要があるので、クエリ系アクションだけを
/// 横取りし、それ以外は ReadonlyHandler に委譲する Handler を自前で書く。
pub const Handler = struct {
    inner: ghostty_vt.ReadonlyHandler,
    alloc: std.mem.Allocator,
    responses: *std.ArrayList(u8),
    title: *?[]u8,
    /// DCS 系アクションは ghostty_vt.Stream が状態を持たず生バイトで
    /// 渡してくるので、組み立ては ghostty 本体と同じこのハンドラに任せる。
    dcs: ghostty_vt.dcs.Handler = .{},

    pub fn init(
        terminal: *ghostty_vt.Terminal,
        alloc: std.mem.Allocator,
        responses: *std.ArrayList(u8),
        title: *?[]u8,
    ) Handler {
        return .{
            .inner = terminal.vtHandler(),
            .alloc = alloc,
            .responses = responses,
            .title = title,
        };
    }

    pub fn deinit(self: *Handler) void {
        // ST が来ないまま入力が途切れると DCS ハンドラが確保したバッファが
        // 残るので、内側より先に捨てる。
        self.dcs.deinit();
        self.inner.deinit();
    }

    pub fn vt(
        self: *Handler,
        comptime action: ghostty_vt.StreamAction.Tag,
        value: ghostty_vt.StreamAction.Value(action),
    ) !void {
        switch (action) {
            .device_status => try self.deviceStatus(value.request),
            .device_attributes => try self.deviceAttributes(value),
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value.mode, value.ansi),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .window_title => try self.setTitle(value.title),
            else => try self.inner.vt(action, value),
        }
    }

    /// 応答値は ghostty 本体の termio ハンドラ (src/termio/stream_handler.zig)
    /// が実際に PTY へ書き込んでいるバイト列と合わせてある。
    fn deviceStatus(self: *Handler, req: ghostty_vt.device_status.Request) !void {
        switch (req) {
            .operating_status => try self.responses.appendSlice(self.alloc, "\x1b[0n"),
            .cursor_position => {
                const t = self.inner.terminal;
                // DECOM (origin mode) 有効時はスクロール領域の左上を原点と
                // した相対座標で応答する (xterm 仕様、ghostty 本体
                // stream_handler.zig の deviceStatusReport と同じ)。
                const pos: struct { x: usize, y: usize } = if (t.modes.get(.origin)) .{
                    .x = t.screens.active.cursor.x -| t.scrolling_region.left,
                    .y = t.screens.active.cursor.y -| t.scrolling_region.top,
                } else .{
                    .x = t.screens.active.cursor.x,
                    .y = t.screens.active.cursor.y,
                };
                var buf: [32]u8 = undefined;
                const resp = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                try self.responses.appendSlice(self.alloc, resp);
            },
            .color_scheme => {},
        }
    }

    fn deviceAttributes(self: *Handler, req: ghostty_vt.DeviceAttributeReq) !void {
        switch (req) {
            .primary => try self.responses.appendSlice(self.alloc, "\x1b[?62;22c"),
            .secondary => try self.responses.appendSlice(self.alloc, "\x1b[>1;10;0c"),
            .tertiary => {},
        }
    }

    /// DECRQM (CSI Ps $ p / CSI ? Ps $ p) への DECRPM 応答。ghostty 本体
    /// と同じく 3 (permanently set) / 4 (permanently reset) は使わず、
    /// 既知モードは現在値の 1 / 2 のみで答える。
    fn requestMode(self: *Handler, mode: ghostty_vt.Mode) !void {
        const tag: ghostty_vt.modes.ModeTag = @bitCast(@intFromEnum(mode));
        const code: u8 = if (self.inner.terminal.modes.get(mode)) 1 else 2;
        var buf: [32]u8 = undefined;
        const resp = try std.fmt.bufPrint(&buf, "\x1b[{s}{d};{d}$y", .{
            if (tag.ansi) "" else "?",
            tag.value,
            code,
        });
        try self.responses.appendSlice(self.alloc, resp);
    }

    fn requestModeUnknown(self: *Handler, mode_raw: u16, ansi: bool) !void {
        var buf: [32]u8 = undefined;
        const resp = try std.fmt.bufPrint(&buf, "\x1b[{s}{d};0$y", .{
            if (ansi) "" else "?",
            mode_raw,
        });
        try self.responses.appendSlice(self.alloc, resp);
    }

    /// kitty keyboard protocol の問い合わせ (CSI ? u) には、アクティブ
    /// 画面のフラグスタック先頭を CSI ? flags u で返す
    /// (ghostty 本体 queryKittyKeyboard と同じ)。push/pop/set 自体は
    /// ReadonlyHandler が Terminal に反映しているので、ここは読むだけ。
    fn queryKittyKeyboard(self: *Handler) !void {
        var buf: [16]u8 = undefined;
        const resp = try std.fmt.bufPrint(&buf, "\x1b[?{d}u", .{
            self.inner.terminal.screens.active.kitty_keyboard.current().int(),
        });
        try self.responses.appendSlice(self.alloc, resp);
    }

    fn dcsHook(self: *Handler, dcs: ghostty_vt.DCS) !void {
        var cmd = self.dcs.hook(self.alloc, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsPut(self: *Handler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsUnhook(self: *Handler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *Handler, cmd: *ghostty_vt.dcs.Command) !void {
        switch (cmd.*) {
            // XTGETTCAP。応答表は同梱する terminfo と同じ定義
            // (ghostty の src/terminfo) から comptime で引くので、
            // 応答値と terminfo データベースが食い違わない。
            .xtgettcap => |*gettcap| {
                const map = comptime ghostty_terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    // 未知のキーは ghostty 本体同様に無応答 (DCS 0 + r ST
                    // すら返さない)。
                    const resp = map.get(key) orelse continue;
                    try self.responses.appendSlice(self.alloc, resp);
                }
            },

            // DECRQSS と tmux control mode は未対応。
            .decrqss, .tmux => {},
        }
    }

    fn setTitle(self: *Handler, title: []const u8) !void {
        // 先に null を入れてから free する: dupe が失敗したとき title.* が
        // 解放済み領域を指したままだと、後続の buildUpdate / Term.deinit が
        // 二重 free してしまう。
        if (self.title.*) |old| {
            self.title.* = null;
            self.alloc.free(old);
        }
        self.title.* = try self.alloc.dupe(u8, title);
    }
};

pub const Stream = ghostty_vt.Stream(Handler);

test "setTitle は dupe 失敗時に旧タイトルを dangling にしない" {
    var title: ?[]u8 = null;
    // fail_index=1: 1回目の setTitle の dupe (allocation 0) は成功し、
    // 2回目の dupe (allocation 1) で OOM を注入する。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var h: Handler = .{
        .inner = undefined,
        .alloc = failing.allocator(),
        .responses = undefined,
        .title = &title,
    };

    try h.setTitle("first");
    try std.testing.expectError(error.OutOfMemory, h.setTitle("second"));
    // 旧タイトルは解放済みなので、解放済み領域を指すくらいなら null であるべき。
    try std.testing.expectEqual(@as(?[]u8, null), title);
}
