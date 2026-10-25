const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const style = @import("style.zig");

pub const Span = style.Span;

/// text と spans と cells をまとめて所有する、1 行分の抽出結果。
pub const Extracted = struct {
    text: []u8,
    spans: []Span,
    /// text の文字 i から始まる書記素のセル数 (1 か 2) を i バイト目に、
    /// 書記素の 2 文字目以降には 0 を持つ。全文字が 1 なら null。
    cells: ?[]u8,

    pub fn deinit(self: *Extracted, alloc: std.mem.Allocator) void {
        for (self.spans) |*s| s.deinit(alloc);
        alloc.free(self.spans);
        alloc.free(self.text);
        if (self.cells) |c| alloc.free(c);
        self.* = undefined;
    }
};

/// セル列 X に対応する、その行の text 内のコードポイント index を返す。
///
/// Emacs 側でセル列から文字位置を求めるには char-width の和を使うしか
/// なかったが、国旗 (regional indicator) のように ghostty が 2 セル・
/// Emacs が 1 桁と数える文字ではずれる。数え方は extractRow の文字の
/// 積み方と 1 対 1 に対応させる。
pub fn cellToIndex(pin: ghostty_vt.Pin, x: usize) usize {
    const cells = pin.cells(.all);
    var index: usize = 0;
    for (cells[0..@min(x, cells.len)]) |*cell| {
        switch (cell.wide) {
            .spacer_tail, .spacer_head => continue,
            .narrow, .wide => {},
        }
        index += 1;
        if (cell.codepoint() != 0 and cell.hasGrapheme()) {
            if (pin.grapheme(cell)) |extra| index += extra.len;
        }
    }
    return index;
}

/// C1 制御 (U+0080-U+009F) を幅 1 の代替文字に差し替える。
///
/// ghostty は UTF-8 端末として C1 を CSI 等に解釈せず 1 セルに格納する
/// が、Emacs はこれを =\\205= のような 4 桁のエスケープ表示にするので、
/// セル列と表示桁がずれてカーソル位置が合わなくなる。落とすと今度は
/// ghostty が数えたセルと文字数がずれるため、1 セル 1 文字のまま
/// 表示幅だけを 1 桁にする。U+FFFD を使うのは、空白へ潰して本物の
/// 空白と区別できなくするより「表現できないものがあった」ことが
/// 読み手に見えるほうがよいため。
fn substituteC1(cp: u21) u21 {
    return if (cp >= 0x80 and cp <= 0x9f) 0xfffd else cp;
}

fn hyperlinkUri(pin: ghostty_vt.Pin, cell: *const ghostty_vt.Cell) ?[]const u8 {
    if (!cell.hyperlink) return null;
    const page = &pin.node.data;
    const id = page.lookupHyperlink(cell) orelse return null;
    const link = page.hyperlink_set.get(page.memory, id);
    return link.uri.slice(page.memory);
}

fn sameUri(a: ?[]const u8, b: ?[]const u8) bool {
    if (a) |av| {
        const bv = b orelse return false;
        return std.mem.eql(u8, av, bv);
    }
    return b == null;
}

/// text は Emacs 文字列と対応させるため常に Unicode コードポイント単位で
/// 数える (バイトオフセットでもセル列でもない)。spacer セルは wide 文字の
/// 継続を示すだけで内容を持たないため読み飛ばす。
///
/// スタイルは TABLE で intern して ID にする。intern は区間を閉じるときの
/// 1 回だけで、セルごとの比較は Style.eql で済ませる。
pub fn extractRow(
    alloc: std.mem.Allocator,
    pin: ghostty_vt.Pin,
    table: *style.Table,
) !Extracted {
    const cells = pin.cells(.all);

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(alloc);
    var spans: std.ArrayList(Span) = .empty;
    errdefer {
        for (spans.items) |*s| s.deinit(alloc);
        spans.deinit(alloc);
    }
    var cell_counts: std.ArrayList(u8) = .empty;
    defer cell_counts.deinit(alloc);
    var all_single = true;

    var cur_style: ?style.Style = null;
    var cur_uri: ?[]const u8 = null;
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
        const this_style = style.Style.fromGhostty(cell_style);

        if (cur_style == null or !cur_style.?.eql(this_style) or !sameUri(cur_uri, uri)) {
            try closeSpan(alloc, table, &spans, cur_style, cur_uri, cur_span_start, cp_index);
            cur_style = this_style;
            cur_uri = uri;
            cur_span_start = cp_index;
        }
        const width: u8 = if (cell.wide == .wide) 2 else 1;
        if (width != 1) all_single = false;
        try cell_counts.append(alloc, width);
        var buf: [4]u8 = undefined;
        const cp = cell.codepoint();
        if (cp == 0) {
            try text.append(alloc, ' ');
            cp_index += 1;
        } else {
            const n = try std.unicode.utf8Encode(substituteC1(cp), &buf);
            try text.appendSlice(alloc, buf[0..n]);
            cp_index += 1;

            if (cell.hasGrapheme()) {
                if (pin.grapheme(cell)) |extra| {
                    for (extra) |ecp| {
                        const en = try std.unicode.utf8Encode(ecp, &buf);
                        try text.appendSlice(alloc, buf[0..en]);
                        try cell_counts.append(alloc, 0);
                        all_single = false;
                        cp_index += 1;
                    }
                }
            }
        }
    }

    try closeSpan(alloc, table, &spans, cur_style, cur_uri, cur_span_start, cp_index);

    const row_cells: ?[]u8 = if (all_single) null else try cell_counts.toOwnedSlice(alloc);
    errdefer if (row_cells) |c| alloc.free(c);
    const owned_text = try text.toOwnedSlice(alloc);
    errdefer alloc.free(owned_text);
    return .{
        .text = owned_text,
        .spans = try spans.toOwnedSlice(alloc),
        .cells = row_cells,
    };
}

/// 既定スタイルの区間まで律儀に span 化すると、装飾のない大半の行が常に
/// span を持つことになり Elisp 側の負担が増えるため、既定スタイルは
/// span を発行しない (span が無い = 既定描画、という約束にする)。
/// ハイパーリンクは装飾ではないが Emacs 側でボタン化が要るので、既定
/// スタイルでも URI が付いていれば span を出す。
fn closeSpan(
    alloc: std.mem.Allocator,
    table: *style.Table,
    spans: *std.ArrayList(Span),
    cur_style: ?style.Style,
    uri: ?[]const u8,
    start: usize,
    end: usize,
) !void {
    const s = cur_style orelse return;
    if (end <= start) return;
    if (s.isDefault() and uri == null) return;
    const owned_uri: ?[]u8 = if (uri) |u| try alloc.dupe(u8, u) else null;
    errdefer if (owned_uri) |u| alloc.free(u);
    try spans.append(alloc, .{
        .start = start,
        .end = end,
        .id = try table.intern(s),
        .hyperlink = owned_uri,
    });
}

test "extractRow は空行から空文字列と空スパンを返す" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    var row = try extractRow(alloc, pin, &table);
    defer row.deinit(alloc);

    try std.testing.expectEqualStrings("     ", row.text);
    try std.testing.expectEqual(@as(usize, 0), row.spans.len);
}

test "extractRow は同じスタイルの区間に同じ ID を振る" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 8, .rows = 2 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    // 赤 aa / 緑 bb / 赤 cc → 同じ赤の 2 区間は同じ ID になる
    t.setCursorPos(1, 1);
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
    try t.printString("aa");
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 9, .g = 9, .b = 9 } });
    try t.printString("bb");
    try t.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
    try t.printString("cc");

    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    var row = try extractRow(alloc, pin, &table);
    defer row.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 3), row.spans.len);
    try std.testing.expectEqual(row.spans[0].id, row.spans[2].id);
    try std.testing.expect(row.spans[0].id != row.spans[1].id);
    try std.testing.expectEqual(@as(usize, 2), table.count());
}

test "extractRow は C1 制御を幅 1 の代替文字に置き換える" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 3, .rows = 1 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    t.setCursorPos(1, 1);
    try t.printString("\u{0085}\u{009b}a");

    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    var row = try extractRow(alloc, pin, &table);
    defer row.deinit(alloc);

    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}a", row.text);
}

/// テスト用: COLS 桁 1 行の端末に S を書いた行の cells を EXPECTED と比べる。
fn expectCells(grapheme_cluster: bool, cols: u16, s: []const u8, expected: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = cols, .rows = 1 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    t.modes.set(.grapheme_cluster, grapheme_cluster);
    t.setCursorPos(1, 1);
    try t.printString(s);
    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    var row = try extractRow(alloc, pin, &table);
    defer row.deinit(alloc);

    if (expected) |e| {
        try std.testing.expectEqualSlices(u8, e, row.cells orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expectEqual(@as(?[]u8, null), row.cells);
    }
}

test "extractRow は全セルが 1 文字 1 セルの行の cells を null にする" {
    try expectCells(true, 4, "ab", null);
    try expectCells(true, 4, "\u{23F1}a", null);
}

test "extractRow の cells は文字ごとに、そこから始まる書記素のセル数を持つ" {
    // 国旗 (RI 2 つ) は 1 書記素 2 セル。2 文字目は書記素の続きなので 0。
    try expectCells(true, 4, "\u{1F1EF}\u{1F1F5}a", &.{ 2, 0, 1, 1 });
    // ZWJ でつないだ家族は 5 コードポイントで 1 書記素 2 セル。
    try expectCells(true, 3, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", &.{ 2, 0, 0, 0, 0, 1 });
    // 肌色修飾と VS16 も 1 書記素 2 セル。
    try expectCells(true, 3, "\u{1F44D}\u{1F3FD}", &.{ 2, 0, 1 });
    try expectCells(true, 3, "\u{2764}\u{FE0F}", &.{ 2, 0, 1 });
    // CJK は 1 文字 2 セル。
    try expectCells(true, 3, "\u{6F22}a", &.{ 2, 1 });
    // RI が 3 つ続くと先頭 2 つが国旗、残る 1 つは単独の 2 セル。
    try expectCells(true, 6, "\u{1F1EF}\u{1F1F5}\u{1F1FA}", &.{ 2, 0, 2, 1, 1 });
}

test "extractRow の cells は mode 2027 無効の国旗を RI ごとの 2 セルにする" {
    try expectCells(false, 4, "\u{1F1EF}\u{1F1F5}", &.{ 2, 2 });
}

/// テスト用: COLS 桁の端末に S を書き、行 Y の cells の長さが text の文字数と一致するか確かめる。
fn expectCellsCoverText(cols: u16, s: []const u8, y: u16) !void {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = cols, .rows = 2 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    t.modes.set(.grapheme_cluster, true);
    t.setCursorPos(1, 1);
    try t.printString(s);
    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = y } }).?;
    var row = try extractRow(alloc, pin, &table);
    defer row.deinit(alloc);

    const cells = row.cells orelse return error.TestExpectedCells;
    try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(row.text), cells.len);
}

test "extractRow の cells は行末で折り返した wide 文字の行でも text の文字数と一致する" {
    // 2 つ目の漢字は 3 桁目に入らず、spacer_head を残して次の行へ折り返す。
    try expectCellsCoverText(3, "\u{6F22}\u{6F22}", 0);
    try expectCellsCoverText(3, "\u{6F22}\u{6F22}", 1);
}

test "extractRow の cells は FE0F を含む ZWJ 列でも text の文字数と一致する" {
    try expectCellsCoverText(4, "\u{1F469}\u{200D}\u{2764}\u{FE0F}\u{200D}\u{1F48B}\u{200D}\u{1F468}", 0);
}

test "cellToIndex は extractRow の文字数と一致する" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var table: style.Table = .init(alloc);
    defer table.deinit();

    // mode 2027 無効の国旗は RI 1 つが 2 セル。セル 4 (= "a") は 3 文字目 (index 2)。
    t.setCursorPos(1, 1);
    try t.printString("\u{1F1EF}\u{1F1F5}ab");
    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    try std.testing.expectEqual(@as(usize, 0), cellToIndex(pin, 0));
    try std.testing.expectEqual(@as(usize, 1), cellToIndex(pin, 2));
    try std.testing.expectEqual(@as(usize, 2), cellToIndex(pin, 4));
    try std.testing.expectEqual(@as(usize, 3), cellToIndex(pin, 5));
}

test "cellToIndex は結合文字ぶんも数える" {
    const alloc = std.testing.allocator;
    var t: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    // DECSET 2027 有効時、肌色修飾は 1 セルに 2 コードポイントで入る。
    t.modes.set(.grapheme_cluster, true);
    t.setCursorPos(1, 1);
    try t.printString("\u{1F44D}\u{1F3FD}a");
    const pin = t.screens.active.pages.pin(.{ .viewport = .{ .y = 0 } }).?;
    try std.testing.expectEqual(@as(usize, 2), cellToIndex(pin, 2));
}
