const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

/// ReadonlyHandler は DSR/DA など応答が必要なアクションを無視する
/// (ghostty のドキュメント通り、応答不要な再生専用ユースケース向けのため)。
/// PTY への応答を組み立てる必要があるので、クエリ系アクションだけを
/// 横取りし、それ以外は ReadonlyHandler に委譲する Handler を自前で書く。
pub const Handler = struct {
    inner: ghostty_vt.ReadonlyHandler,
    alloc: std.mem.Allocator,
    responses: *std.ArrayList(u8),
    title: *?[]u8,

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
                var buf: [32]u8 = undefined;
                const resp = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{
                    t.screens.active.cursor.y + 1,
                    t.screens.active.cursor.x + 1,
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

    fn setTitle(self: *Handler, title: []const u8) !void {
        if (self.title.*) |old| self.alloc.free(old);
        self.title.* = try self.alloc.dupe(u8, title);
    }
};

pub const Stream = ghostty_vt.Stream(Handler);
