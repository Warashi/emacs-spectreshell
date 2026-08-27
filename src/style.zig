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

/// ハイパーリンク URI は Style に含めない。Style は Table で intern して
/// ID 化する対象であり、URI を含めると (a) URI ごとに別スタイルが増えて
/// テーブルが膨らみ、(b) 所有権のある文字列を持つためハッシュキーにできない。
/// URI は face とも無関係 (Emacs 側ではボタン化に使う) なので Span 側が持つ。
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    underline: Underline = .none,
    strikethrough: bool = false,
    inverse: bool = false,

    pub fn fromGhostty(gs: ghostty_vt.Style) Style {
        return .{
            .fg = Color.fromGhostty(gs.fg_color),
            .bg = Color.fromGhostty(gs.bg_color),
            .bold = gs.flags.bold,
            .italic = gs.flags.italic,
            .faint = gs.flags.faint,
            .underline = Underline.fromGhostty(gs.flags.underline),
            .strikethrough = gs.flags.strikethrough,
            .inverse = gs.flags.inverse,
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
            !self.inverse;
    }

    pub fn eql(a: Style, b: Style) bool {
        if (!a.fg.eql(b.fg)) return false;
        if (!a.bg.eql(b.bg)) return false;
        if (a.bold != b.bold) return false;
        if (a.italic != b.italic) return false;
        if (a.faint != b.faint) return false;
        if (a.underline != b.underline) return false;
        if (a.strikethrough != b.strikethrough) return false;
        return a.inverse == b.inverse;
    }
};

pub const StyleId = u32;

/// Style を ID に intern するテーブル。同じ端末が生きている間 ID は安定
/// なので、Emacs 側は「初出のときだけ送られてくる ID→スタイル」を覚えて
/// face をキャッシュでき、スパンごとのスタイル構築をやめられる。
///
/// ID は 0 から連番。新規登録は必ず末尾に積まれるので、update 構築の前後
/// で count() を比べれば「この update で初出のスタイル」が since() で取れる。
pub const Table = struct {
    alloc: std.mem.Allocator,
    map: std.AutoHashMapUnmanaged(Style, StyleId) = .empty,
    styles: std.ArrayListUnmanaged(Style) = .empty,

    pub fn init(alloc: std.mem.Allocator) Table {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Table) void {
        self.map.deinit(self.alloc);
        self.styles.deinit(self.alloc);
        self.* = undefined;
    }

    pub fn intern(self: *Table, s: Style) !StyleId {
        const gop = try self.map.getOrPut(self.alloc, s);
        if (!gop.found_existing) {
            const id: StyleId = @intCast(self.styles.items.len);
            errdefer _ = self.map.remove(s);
            try self.styles.append(self.alloc, s);
            gop.value_ptr.* = id;
        }
        return gop.value_ptr.*;
    }

    pub fn get(self: *const Table, id: StyleId) Style {
        return self.styles.items[id];
    }

    pub fn count(self: *const Table) usize {
        return self.styles.items.len;
    }

    /// ID が MARK 以降のスタイル (= その時点以降に初出だったもの) を返す。
    pub fn since(self: *const Table, mark: usize) []const Style {
        return self.styles.items[mark..];
    }

    pub fn clear(self: *Table) void {
        self.map.clearRetainingCapacity();
        self.styles.clearRetainingCapacity();
    }
};

/// text 内のコードポイントオフセット [start, end) に対応するスタイル区間。
/// hyperlink は alloc で複製した所有スライス。
pub const Span = struct {
    start: usize,
    end: usize,
    id: StyleId,
    hyperlink: ?[]u8 = null,

    pub fn deinit(self: *Span, alloc: std.mem.Allocator) void {
        if (self.hyperlink) |uri| alloc.free(uri);
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

test "Style.isDefault は装飾が1つでもあれば偽になる" {
    var s: Style = .{};
    try std.testing.expect(s.isDefault());
    s.bold = true;
    try std.testing.expect(!s.isDefault());
}

test "Style.eql は全フィールドを比較する" {
    try std.testing.expect(Style.eql(.{ .bold = true }, .{ .bold = true }));
    try std.testing.expect(!Style.eql(.{ .bold = true }, .{ .italic = true }));
    try std.testing.expect(!Style.eql(.{ .fg = .{ .palette = 1 } }, .{ .fg = .{ .palette = 2 } }));
}

test "Table.intern は同じスタイルに同じ ID を返す" {
    const alloc = std.testing.allocator;
    var table: Table = .init(alloc);
    defer table.deinit();

    const a = try table.intern(.{ .bold = true });
    const b = try table.intern(.{ .bold = true });
    const c = try table.intern(.{ .italic = true });
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expectEqual(@as(usize, 2), table.count());
}

test "Table.since はその位置以降に新しく登録されたスタイルだけを返す" {
    const alloc = std.testing.allocator;
    var table: Table = .init(alloc);
    defer table.deinit();

    _ = try table.intern(.{ .bold = true });
    const mark = table.count();
    _ = try table.intern(.{ .bold = true }); // 既出なので増えない
    const id = try table.intern(.{ .faint = true });

    const news = table.since(mark);
    try std.testing.expectEqual(@as(usize, 1), news.len);
    try std.testing.expectEqual(@as(StyleId, id), @as(StyleId, @intCast(mark)));
    try std.testing.expect(news[0].faint);
}

test "Table.clear は ID を 0 から振り直す" {
    const alloc = std.testing.allocator;
    var table: Table = .init(alloc);
    defer table.deinit();

    _ = try table.intern(.{ .bold = true });
    const before = try table.intern(.{ .italic = true });
    table.clear();
    try std.testing.expectEqual(@as(usize, 0), table.count());
    const after = try table.intern(.{ .italic = true });
    try std.testing.expect(before != after);
    try std.testing.expectEqual(@as(StyleId, 0), after);
}
