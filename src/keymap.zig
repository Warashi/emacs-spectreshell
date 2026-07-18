const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const Key = ghostty_vt.input.Key;
const Mods = ghostty_vt.input.KeyMods;
const KeyEvent = ghostty_vt.input.KeyEvent;

/// design.md の KEY 中間表現で使う特殊キーシンボル名 (Emacs 側 symbol-name)
/// から ghostty-vt の Key enum への対応表。矢印・編集キー・ファンクション
/// キーのみ (design.md の semi-char モードで送る範囲)。
const named_keys = [_]struct { name: []const u8, key: Key }{
    .{ .name = "up", .key = .arrow_up },
    .{ .name = "down", .key = .arrow_down },
    .{ .name = "left", .key = .arrow_left },
    .{ .name = "right", .key = .arrow_right },
    .{ .name = "home", .key = .home },
    .{ .name = "end", .key = .end },
    .{ .name = "prior", .key = .page_up },
    .{ .name = "next", .key = .page_down },
    .{ .name = "insert", .key = .insert },
    .{ .name = "delete", .key = .delete },
    .{ .name = "backspace", .key = .backspace },
    .{ .name = "tab", .key = .tab },
    .{ .name = "return", .key = .enter },
    .{ .name = "escape", .key = .escape },
    .{ .name = "f1", .key = .f1 },
    .{ .name = "f2", .key = .f2 },
    .{ .name = "f3", .key = .f3 },
    .{ .name = "f4", .key = .f4 },
    .{ .name = "f5", .key = .f5 },
    .{ .name = "f6", .key = .f6 },
    .{ .name = "f7", .key = .f7 },
    .{ .name = "f8", .key = .f8 },
    .{ .name = "f9", .key = .f9 },
    .{ .name = "f10", .key = .f10 },
    .{ .name = "f11", .key = .f11 },
    .{ .name = "f12", .key = .f12 },
};

pub fn namedKey(name: []const u8) ?Key {
    for (named_keys) |nk| {
        if (std.mem.eql(u8, nk.name, name)) return nk.key;
    }
    return null;
}

/// design.md の MODIFIERS シンボル (ctrl alt shift super) を Mods に立てる。
/// 未知のシンボルは無視する (呼び出し側で無視してよいノイズ扱いにする方が、
/// Phase 4 側のキーマップ実装の自由度を保てるため)。認識できたら true。
pub fn applyModifierName(mods: *Mods, name: []const u8) bool {
    if (std.mem.eql(u8, name, "ctrl")) {
        mods.ctrl = true;
        return true;
    }
    if (std.mem.eql(u8, name, "alt")) {
        mods.alt = true;
        return true;
    }
    if (std.mem.eql(u8, name, "shift")) {
        mods.shift = true;
        return true;
    }
    if (std.mem.eql(u8, name, "super")) {
        mods.super = true;
        return true;
    }
    return false;
}

/// 印字可能な 1 コードポイントの KeyEvent を組み立てる。ctrl+<ascii> の
/// エンコードは ghostty-vt 側が utf8.len==1 の1バイトを直接使う実装なので、
/// key enum は補助情報にとどまり utf8 が主となる。
pub fn charEvent(cp: u21, utf8: []const u8, mods: Mods) KeyEvent {
    const key: Key = if (cp < 128) (Key.fromASCII(@intCast(cp)) orelse .unidentified) else .unidentified;
    const unshifted: u21 = if (cp < 128) cp else 0;
    return .{
        .key = key,
        .utf8 = utf8,
        .unshifted_codepoint = unshifted,
        .mods = mods,
    };
}

/// 特殊キー (矢印・編集キー等) の KeyEvent。utf8 は空のままにして
/// pcStyleFunctionKey 側のマッチに委ねる。
pub fn namedKeyEvent(key: Key, mods: Mods) KeyEvent {
    return .{ .key = key, .mods = mods };
}

const testing = std.testing;

test "namedKey は既知の特殊キー名を Key に変換する" {
    try testing.expectEqual(Key.arrow_up, namedKey("up").?);
    try testing.expectEqual(Key.f12, namedKey("f12").?);
    try testing.expectEqual(@as(?Key, null), namedKey("no-such-key"));
}

test "applyModifierName は既知の修飾子だけ Mods に反映する" {
    var mods: Mods = .{};
    try testing.expect(applyModifierName(&mods, "ctrl"));
    try testing.expect(applyModifierName(&mods, "alt"));
    try testing.expect(!applyModifierName(&mods, "hyper"));
    try testing.expect(mods.ctrl);
    try testing.expect(mods.alt);
    try testing.expect(!mods.shift);
}

test "charEvent は ascii 文字を Key.fromASCII と紐付ける" {
    const ev = charEvent('a', "a", .{});
    try testing.expectEqual(Key.key_a, ev.key);
    try testing.expectEqualStrings("a", ev.utf8);
    try testing.expectEqual(@as(u21, 'a'), ev.unshifted_codepoint);
}

test "charEvent は非 ascii 文字を unidentified のまま utf8 だけで運ぶ" {
    const ev = charEvent('あ', "あ", .{});
    try testing.expectEqual(Key.unidentified, ev.key);
    try testing.expectEqualStrings("あ", ev.utf8);
    try testing.expectEqual(@as(u21, 0), ev.unshifted_codepoint);
}
