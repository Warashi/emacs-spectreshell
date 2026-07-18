const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const style = @import("style.zig");

pub const Span = style.Span;

/// text と spans をまとめて所有する、1 行分の抽出結果。
pub const Extracted = struct {
    text: []u8,
    spans: []Span,

    pub fn deinit(self: *Extracted, alloc: std.mem.Allocator) void {
        for (self.spans) |*s| s.deinit(alloc);
        alloc.free(self.spans);
        alloc.free(self.text);
        self.* = undefined;
    }
};

fn hyperlinkUri(pin: ghostty_vt.Pin, cell: *const ghostty_vt.Cell) ?[]const u8 {
    if (!cell.hyperlink) return null;
    const page = &pin.node.data;
    const id = page.lookupHyperlink(cell) orelse return null;
    const link = page.hyperlink_set.get(page.memory, id);
    return link.uri.slice(page.memory);
}

/// text は Emacs 文字列と対応させるため常に Unicode コードポイント単位で
/// 数える (バイトオフセットでもセル列でもない)。spacer セルは wide 文字の
/// 継続を示すだけで内容を持たないため読み飛ばす。
pub fn extractRow(alloc: std.mem.Allocator, pin: ghostty_vt.Pin) !Extracted {
    const cells = pin.cells(.all);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var spans: std.ArrayList(Span) = .empty;
    errdefer {
        for (spans.items) |*s| s.deinit(alloc);
        spans.deinit(alloc);
    }

    var cur_style: ?style.Style = null;
    var cur_span_start: usize = 0;
    var cp_index: usize = 0;

    for (cells) |*cell| {
        switch (cell.wide) {
            .spacer_tail, .spacer_head => continue,
            .narrow, .wide => {},
        }

        const cell_style = if (cell.hasStyling())
            pin.style(cell)
        else
            ghostty_vt.Style{};
        const uri = hyperlinkUri(pin, cell);
        const this_style = style.Style.fromGhostty(cell_style, uri);

        if (cur_style == null or !cur_style.?.eql(this_style)) {
            try closeSpan(alloc, &spans, cur_style, cur_span_start, cp_index);
            cur_style = this_style;
            cur_span_start = cp_index;
        }

        var buf: [4]u8 = undefined;
        const cp = cell.codepoint();
        if (cp == 0) {
            try text.append(alloc, ' ');
            cp_index += 1;
        } else {
            const n = try std.unicode.utf8Encode(cp, &buf);
            try text.appendSlice(alloc, buf[0..n]);
            cp_index += 1;

            if (cell.hasGrapheme()) {
                if (pin.grapheme(cell)) |extra| {
                    for (extra) |ecp| {
                        const en = try std.unicode.utf8Encode(ecp, &buf);
                        try text.appendSlice(alloc, buf[0..en]);
                        cp_index += 1;
                    }
                }
            }
        }
    }

    try closeSpan(alloc, &spans, cur_style, cur_span_start, cp_index);

    return .{
        .text = try text.toOwnedSlice(alloc),
        .spans = try spans.toOwnedSlice(alloc),
    };
}

/// 既定スタイルの区間まで律儀に span 化すると、装飾のない大半の行が常に
/// span を持つことになり Elisp 側の負担が増えるため、既定スタイルは
/// span を発行しない (span が無い = 既定描画、という約束にする)。
fn closeSpan(
    alloc: std.mem.Allocator,
    spans: *std.ArrayList(Span),
    cur_style: ?style.Style,
    start: usize,
    end: usize,
) !void {
    const s = cur_style orelse return;
    if (end <= start) return;
    if (s.isDefault()) return;
    try spans.append(alloc, .{
        .start = start,
        .end = end,
        .style = try s.dupe(alloc),
    });
}

test "extractRow は空行から空文字列と空スパンを返す" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    var row = try extractRow(alloc, pin);
    defer row.deinit(alloc);

    try std.testing.expectEqualStrings("     ", row.text);
    try std.testing.expectEqual(@as(usize, 0), row.spans.len);
}
