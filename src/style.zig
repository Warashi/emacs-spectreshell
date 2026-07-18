const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

/// パレット index を直接持たせるのは、パレット→RGB 解決を Emacs 側の
/// テーマ設定 (spectreshell-color-N face) に委ねる設計 (design.org) のため。
pub const Color = union(enum) {
    default,
    palette: u8,
    rgb: Rgb,

    pub const Rgb = struct { r: u8, g: u8, b: u8 };

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .palette => |pa| switch (b) {
                .palette => |pb| pa == pb,
                else => false,
            },
            .rgb => |ra| switch (b) {
                .rgb => |rb| ra.r == rb.r and ra.g == rb.g and ra.b == rb.b,
                else => false,
            },
        };
    }

    fn fromGhostty(c: ghostty_vt.Style.Color) Color {
        return switch (c) {
            .none => .default,
            .palette => |p| .{ .palette = p },
            .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
        };
    }
};

pub const Underline = enum {
    none,
    single,
    double,
    curly,
    dotted,
    dashed,

    fn fromGhostty(u: ghostty_vt.sgr.Attribute.Underline) Underline {
        return switch (u) {
            .none => .none,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
    }
};

/// hyperlink はスパン比較・所有権管理を span 抽出側に委ねるため、ここでは
/// 借用スライスとして保持する (span 確定時に呼び出し側が dupe する)。
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: Underline = .none,
    strikethrough: bool = false,
    inverse: bool = false,
    hyperlink: ?[]const u8 = null,

    pub fn fromGhostty(gs: ghostty_vt.Style, hyperlink: ?[]const u8) Style {
        return .{
            .fg = Color.fromGhostty(gs.fg_color),
            .bg = Color.fromGhostty(gs.bg_color),
            .bold = gs.flags.bold,
            .italic = gs.flags.italic,
            .faint = gs.flags.faint,
            .underline = Underline.fromGhostty(gs.flags.underline),
            .strikethrough = gs.flags.strikethrough,
            .inverse = gs.flags.inverse,
            .hyperlink = hyperlink,
        };
    }

    pub fn isDefault(self: Style) bool {
        return self.fg.eql(.default) and
            self.bg.eql(.default) and
            !self.bold and
            !self.italic and
            !self.faint and
            self.underline == .none and
            !self.strikethrough and
            !self.inverse and
            self.hyperlink == null;
    }

    pub fn eql(a: Style, b: Style) bool {
        if (!a.fg.eql(b.fg)) return false;
        if (!a.bg.eql(b.bg)) return false;
        if (a.bold != b.bold) return false;
        if (a.italic != b.italic) return false;
        if (a.faint != b.faint) return false;
        if (a.underline != b.underline) return false;
        if (a.strikethrough != b.strikethrough) return false;
        if (a.inverse != b.inverse) return false;
        if (a.hyperlink) |ah| {
            const bh = b.hyperlink orelse return false;
            return std.mem.eql(u8, ah, bh);
        }
        return b.hyperlink == null;
    }

    /// alloc で複製した完全に所有されたコピーを返す。
    pub fn dupe(self: Style, alloc: std.mem.Allocator) !Style {
        var copy = self;
        if (self.hyperlink) |uri| copy.hyperlink = try alloc.dupe(u8, uri);
        return copy;
    }

    pub fn deinit(self: *Style, alloc: std.mem.Allocator) void {
        if (self.hyperlink) |uri| alloc.free(uri);
        self.* = undefined;
    }
};

/// text 内のコードポイントオフセット [start, end) に対応するスタイル区間。
pub const Span = struct {
    start: usize,
    end: usize,
    style: Style,

    pub fn deinit(self: *Span, alloc: std.mem.Allocator) void {
        self.style.deinit(alloc);
        self.* = undefined;
    }
};

test "Color eql は同種同値のみ真" {
    try std.testing.expect(Color.eql(.default, .default));
    try std.testing.expect(Color.eql(.{ .palette = 3 }, .{ .palette = 3 }));
    try std.testing.expect(!Color.eql(.{ .palette = 3 }, .{ .palette = 4 }));
    try std.testing.expect(Color.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try std.testing.expect(!Color.eql(.{ .palette = 3 }, .default));
}

test "Style.isDefault はハイパーリンクありで偽になる" {
    var s: Style = .{};
    try std.testing.expect(s.isDefault());
    s.hyperlink = "https://example.com";
    try std.testing.expect(!s.isDefault());
}

test "Style.eql はハイパーリンク文字列の中身を比較する" {
    const a: Style = .{ .hyperlink = "https://a" };
    const b: Style = .{ .hyperlink = "https://a" };
    const c: Style = .{ .hyperlink = "https://b" };
    try std.testing.expect(Style.eql(a, b));
    try std.testing.expect(!Style.eql(a, c));
}
