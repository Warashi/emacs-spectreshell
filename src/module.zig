const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const emacs = @import("emacs.zig");
const core = @import("core.zig");
const style = @import("style.zig");
const keymap = @import("keymap.zig");

/// Term はユーザーの Elisp コードが保持する限り生き続けるため、Term.init
/// に渡す確保元は per-call のスコープを持たないプロセス全体の allocator
/// にする必要がある (関数呼び出しごとの arena には置けない)。
const term_alloc = std.heap.smp_allocator;

/// 呼び出しごとに使い捨てる作業領域。Update の中身も丸ごとここに載せて
/// しまえば、Lisp 値への変換が終わった時点で arena.deinit() 一発で
/// Update.deinit() 相当の後片付けが完了する。
fn scratchArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(term_alloc);
}

/// エラーセットは各実装関数の推論に任せる (core.Term 側のエラー集合を
/// ここで手書きすると Phase 1 の変更に追従できず壊れるため)。
/// error.PendingLispSignal は「Emacs 側の env 関数が既に non-local exit を
/// 積んだ」ことを示す印としてのみ使う。finish() はこの場合に signal を
/// 重ねて呼ばないことで、非local exit の二重設定 (未定義動作) を避ける。
fn finish(env: *emacs.Env, result: anyerror!*emacs.Value) *emacs.Value {
    return result catch |err| {
        if (err != error.PendingLispSignal) {
            emacs.signalError(env, @errorName(err));
        }
        return emacs.nilv(env);
    };
}

// ---------------------------------------------------------------------
// user-ptr (Term) の型検証と寿命管理
// ---------------------------------------------------------------------

/// make_user_ptr に登録する finalizer。get_user_finalizer で取り出した
/// 関数ポインタとこの関数のアドレスを比較することで、「他モジュールの
/// user-ptr や生の整数」を「うちの Term」から見分ける型タグ代わりに使う
/// (Emacs の user-ptr にはモジュール独自の型情報を持たせる仕組みがない)。
fn termFinalizer(data: ?*anyopaque) callconv(.c) void {
    const ptr = data orelse return;
    const term: *core.Term = @ptrCast(@alignCast(ptr));
    term.deinit();
}

fn signalNotTerm(env: *emacs.Env, value: *emacs.Value) error{PendingLispSignal} {
    emacs.signalWrongType(env, "spectreshell--term-p", value);
    return error.PendingLispSignal;
}

fn checkTermType(env: *emacs.Env, value: *emacs.Value) !void {
    const ty = emacs.typeOf(env, value);
    if (!emacs.eq(env, ty, emacs.intern(env, "user-ptr"))) return signalNotTerm(env, value);
    const fin = emacs.getUserFinalizer(env, value) orelse return signalNotTerm(env, value);
    if (fin != &termFinalizer) return signalNotTerm(env, value);
}

/// 解放済み (get_user_ptr が null) の場合は spectreshell-terminal-released
/// を signal する。二重解放そのもの (--release の再呼び出し) はここを
/// 経由しないので落ちない。
fn getTerm(env: *emacs.Env, value: *emacs.Value) !*core.Term {
    try checkTermType(env, value);
    const ptr = emacs.getUserPtr(env, value) orelse {
        emacs.nonLocalExitSignal(
            env,
            emacs.intern(env, "spectreshell-terminal-released"),
            emacs.list(env, &.{value}),
        );
        return error.PendingLispSignal;
    };
    return @ptrCast(@alignCast(ptr));
}

fn extractDim(env: *emacs.Env, value: *emacs.Value) !u16 {
    const n = emacs.extractInteger(env, value);
    if (emacs.pendingExit(env)) return error.PendingLispSignal;
    if (n < 1 or n > std.math.maxInt(u16)) {
        emacs.nonLocalExitSignal(env, emacs.intern(env, "args-out-of-range"), emacs.list(env, &.{value}));
        return error.PendingLispSignal;
    }
    return @intCast(n);
}

// ---------------------------------------------------------------------
// Update -> plist 変換 (docs/module-api.org の形式)
// ---------------------------------------------------------------------

fn colorValue(env: *emacs.Env, c: style.Color) ?*emacs.Value {
    return switch (c) {
        .default => null,
        .palette => |p| emacs.makeInteger(env, p),
        .rgb => |rgb| blk: {
            var buf: [7]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }) catch unreachable;
            break :blk emacs.makeString(env, s);
        },
    };
}

fn underlineValue(env: *emacs.Env, u: style.Underline) ?*emacs.Value {
    return switch (u) {
        .none => null,
        .single => emacs.t(env),
        .double => emacs.intern(env, "double"),
        .curly => emacs.intern(env, "curly"),
        .dotted => emacs.intern(env, "dotted"),
        .dashed => emacs.intern(env, "dashed"),
    };
}

/// STYLE-PLIST の中身をキーワード/値ペアとして items に積む。装飾なしの
/// フィールドはキーごと省略する (docs/module-api.org の約束)。
fn pushStyleItems(
    env: *emacs.Env,
    arena: std.mem.Allocator,
    items: *std.ArrayList(*emacs.Value),
    s: style.Style,
) !void {
    if (colorValue(env, s.fg)) |v| {
        try items.append(arena, emacs.intern(env, ":fg"));
        try items.append(arena, v);
    }
    if (colorValue(env, s.bg)) |v| {
        try items.append(arena, emacs.intern(env, ":bg"));
        try items.append(arena, v);
    }
    if (s.bold) {
        try items.append(arena, emacs.intern(env, ":bold"));
        try items.append(arena, emacs.t(env));
    }
    if (s.italic) {
        try items.append(arena, emacs.intern(env, ":italic"));
        try items.append(arena, emacs.t(env));
    }
    if (s.faint) {
        try items.append(arena, emacs.intern(env, ":faint"));
        try items.append(arena, emacs.t(env));
    }
    if (underlineValue(env, s.underline)) |v| {
        try items.append(arena, emacs.intern(env, ":underline"));
        try items.append(arena, v);
    }
    if (s.strikethrough) {
        try items.append(arena, emacs.intern(env, ":strikethrough"));
        try items.append(arena, emacs.t(env));
    }
    if (s.inverse) {
        try items.append(arena, emacs.intern(env, ":inverse"));
        try items.append(arena, emacs.t(env));
    }
    if (s.hyperlink) |uri| {
        try items.append(arena, emacs.intern(env, ":hyperlink"));
        try items.append(arena, emacs.makeString(env, uri));
    }
}

/// SPANS の1要素 (START END . STYLE-PLIST)。STYLE-PLIST は真のリストなので
/// ドット対の末尾に連結しても平らな proper list として構築できる。
fn spanValue(env: *emacs.Env, arena: std.mem.Allocator, span: style.Span) !*emacs.Value {
    var items: std.ArrayList(*emacs.Value) = .empty;
    try items.append(arena, emacs.makeInteger(env, @intCast(span.start)));
    try items.append(arena, emacs.makeInteger(env, @intCast(span.end)));
    try pushStyleItems(env, arena, &items, span.style);
    return emacs.list(env, items.items);
}

fn spansListValue(env: *emacs.Env, arena: std.mem.Allocator, spans: []const style.Span) !*emacs.Value {
    var items: std.ArrayList(*emacs.Value) = .empty;
    for (spans) |s| try items.append(arena, try spanValue(env, arena, s));
    return emacs.list(env, items.items);
}

/// :dirty の1要素 (ROW TEXT SPANS)。
fn dirtyRowValue(env: *emacs.Env, arena: std.mem.Allocator, d: core.DirtyRow) !*emacs.Value {
    const text = emacs.makeString(env, d.text);
    const spans = try spansListValue(env, arena, d.spans);
    return emacs.list(env, &.{ emacs.makeInteger(env, @intCast(d.row)), text, spans });
}

/// :scrolled-off の1要素 (TEXT . SPANS)。SPANS はリストそのものを cdr に
/// 持たせる正真正銘のドット対 (proper list である TEXT の後ろに続けるのとは違う)。
fn scrolledOffValue(env: *emacs.Env, arena: std.mem.Allocator, r: core.Row) !*emacs.Value {
    const text = emacs.makeString(env, r.text);
    const spans = try spansListValue(env, arena, r.spans);
    return emacs.cons(env, text, spans);
}

fn buildUpdatePlist(env: *emacs.Env, arena: std.mem.Allocator, update: *const core.Update) !*emacs.Value {
    var items: std.ArrayList(*emacs.Value) = .empty;

    {
        var rows: std.ArrayList(*emacs.Value) = .empty;
        for (update.dirty) |d| try rows.append(arena, try dirtyRowValue(env, arena, d));
        try items.append(arena, emacs.intern(env, ":dirty"));
        try items.append(arena, emacs.list(env, rows.items));
    }

    {
        var rows: std.ArrayList(*emacs.Value) = .empty;
        for (update.scrolled_off) |r| try rows.append(arena, try scrolledOffValue(env, arena, r));
        try items.append(arena, emacs.intern(env, ":scrolled-off"));
        try items.append(arena, emacs.list(env, rows.items));
    }

    try items.append(arena, emacs.intern(env, ":cursor"));
    try items.append(arena, emacs.cons(
        env,
        emacs.makeInteger(env, @intCast(update.cursor.row)),
        emacs.makeInteger(env, @intCast(update.cursor.col)),
    ));

    try items.append(arena, emacs.intern(env, ":cursor-visible"));
    try items.append(arena, if (update.cursor.visible) emacs.t(env) else emacs.nilv(env));

    if (update.responses.len > 0) {
        try items.append(arena, emacs.intern(env, ":responses"));
        try items.append(arena, emacs.makeUnibyteString(env, update.responses));
    }

    switch (update.alt_screen) {
        .unchanged => {},
        .entered => {
            try items.append(arena, emacs.intern(env, ":alt-screen"));
            try items.append(arena, emacs.intern(env, "entered"));
        },
        .left => {
            try items.append(arena, emacs.intern(env, ":alt-screen"));
            try items.append(arena, emacs.intern(env, "left"));
        },
    }

    if (update.title) |title| {
        try items.append(arena, emacs.intern(env, ":title"));
        try items.append(arena, emacs.makeString(env, title));
    }

    return emacs.list(env, items.items);
}

// ---------------------------------------------------------------------
// KEY / MODIFIERS -> ghostty_vt.input.KeyEvent
// ---------------------------------------------------------------------

/// 修飾子リストの走査上限。正当なリストは高々 4 要素 (ctrl/alt/shift/super)
/// なので、これを超えるのは循環リスト。上限なしで cdr を辿り続けると
/// should_quit を見ないループのため C-g も効かず Emacs がハングする。
const max_modifier_list_len = 64;

fn collectModifiers(env: *emacs.Env, arena: std.mem.Allocator, mods_list: *emacs.Value) !ghostty_vt.input.KeyMods {
    var mods: ghostty_vt.input.KeyMods = .{};
    var cur = mods_list;
    const nil = emacs.nilv(env);
    var remaining: usize = max_modifier_list_len;
    while (!emacs.eq(env, cur, nil)) {
        if (remaining == 0) return error.CircularList;
        remaining -= 1;
        const head = emacs.funcall(env, emacs.intern(env, "car"), &.{cur});
        const name_val = emacs.funcall(env, emacs.intern(env, "symbol-name"), &.{head});
        if (emacs.pendingExit(env)) return error.PendingLispSignal;
        const name = try emacs.copyStringContents(env, arena, name_val);
        _ = keymap.applyModifierName(&mods, name);
        cur = emacs.funcall(env, emacs.intern(env, "cdr"), &.{cur});
        if (emacs.pendingExit(env)) return error.PendingLispSignal;
    }
    return mods;
}

/// KEY は「印字可能文字1文字の文字列」か「特殊キーのシンボル」のどちらか
/// (design.org)。type-of で分岐する。
fn buildKeyEvent(
    env: *emacs.Env,
    arena: std.mem.Allocator,
    key_val: *emacs.Value,
    mods_val: *emacs.Value,
) !ghostty_vt.input.KeyEvent {
    const mods = try collectModifiers(env, arena, mods_val);

    const ty = emacs.typeOf(env, key_val);
    if (emacs.eq(env, ty, emacs.intern(env, "string"))) {
        const bytes = try emacs.copyStringContents(env, arena, key_val);
        const view = std.unicode.Utf8View.init(bytes) catch return error.TypeMismatch;
        var it = view.iterator();
        const cp = it.nextCodepoint() orelse return error.TypeMismatch;
        if (it.nextCodepoint() != null) return error.TypeMismatch;
        return keymap.charEvent(cp, bytes, mods);
    }

    const name_val = emacs.funcall(env, emacs.intern(env, "symbol-name"), &.{key_val});
    if (emacs.pendingExit(env)) return error.PendingLispSignal;
    const name = try emacs.copyStringContents(env, arena, name_val);
    const key = keymap.namedKey(name) orelse return error.TypeMismatch;
    return keymap.namedKeyEvent(key, mods);
}

// ---------------------------------------------------------------------
// BUTTON / ACTION / ROW / COL / MODIFIERS -> core.Term.encodeMouse 引数
// ---------------------------------------------------------------------

/// ROW/COL は 0-origin の端末座標 (docs/module-api.org)。extractDim と違い
/// 0 も許すため上限のみ (u16 幅の端末に収まる座標だけを受け付ける) 別に
/// 検査する。
fn extractCoord(env: *emacs.Env, value: *emacs.Value) !usize {
    const n = emacs.extractInteger(env, value);
    if (emacs.pendingExit(env)) return error.PendingLispSignal;
    if (n < 0 or n > std.math.maxInt(u16)) {
        emacs.nonLocalExitSignal(env, emacs.intern(env, "args-out-of-range"), emacs.list(env, &.{value}));
        return error.PendingLispSignal;
    }
    return @intCast(n);
}

/// BUTTON は nil (ボタンなしの motion) か、整数 1/2/3 (left/middle/right、
/// X11 のボタン番号慣習) か、`wheel-up`/`wheel-down`/`wheel-left`/
/// `wheel-right` シンボルのいずれか (design.org の中間表現)。
fn buildMouseButton(env: *emacs.Env, arena: std.mem.Allocator, value: *emacs.Value) !?core.MouseButton {
    const nil = emacs.nilv(env);
    if (emacs.eq(env, value, nil)) return null;

    const ty = emacs.typeOf(env, value);
    if (emacs.eq(env, ty, emacs.intern(env, "integer"))) {
        const n = emacs.extractInteger(env, value);
        if (emacs.pendingExit(env)) return error.PendingLispSignal;
        return switch (n) {
            1 => .left,
            2 => .middle,
            3 => .right,
            else => error.TypeMismatch,
        };
    }

    const name_val = emacs.funcall(env, emacs.intern(env, "symbol-name"), &.{value});
    if (emacs.pendingExit(env)) return error.PendingLispSignal;
    const name = try emacs.copyStringContents(env, arena, name_val);
    if (std.mem.eql(u8, name, "wheel-up")) return .wheel_up;
    if (std.mem.eql(u8, name, "wheel-down")) return .wheel_down;
    if (std.mem.eql(u8, name, "wheel-left")) return .wheel_left;
    if (std.mem.eql(u8, name, "wheel-right")) return .wheel_right;
    return error.TypeMismatch;
}

/// ACTION は `press`/`release`/`motion` シンボルのいずれか (design.org)。
fn buildMouseAction(env: *emacs.Env, arena: std.mem.Allocator, value: *emacs.Value) !core.MouseAction {
    const name_val = emacs.funcall(env, emacs.intern(env, "symbol-name"), &.{value});
    if (emacs.pendingExit(env)) return error.PendingLispSignal;
    const name = try emacs.copyStringContents(env, arena, name_val);
    if (std.mem.eql(u8, name, "press")) return .press;
    if (std.mem.eql(u8, name, "release")) return .release;
    if (std.mem.eql(u8, name, "motion")) return .motion;
    return error.TypeMismatch;
}

/// MODIFIERS は encode-key と同じ `ctrl`/`alt`/`shift`/`super` のリストだが、
/// core.MouseMods (ghostty Surface.mouseReport 由来) は super を表現できない
/// ので黙って無視する (未知のシンボル同様、呼び出し側の負担を増やさない
/// ためエラーにはしない)。
fn collectMouseMods(env: *emacs.Env, arena: std.mem.Allocator, mods_list: *emacs.Value) !core.MouseMods {
    var mods: core.MouseMods = .{};
    var cur = mods_list;
    const nil = emacs.nilv(env);
    var remaining: usize = max_modifier_list_len;
    while (!emacs.eq(env, cur, nil)) {
        if (remaining == 0) return error.CircularList;
        remaining -= 1;
        const head = emacs.funcall(env, emacs.intern(env, "car"), &.{cur});
        const name_val = emacs.funcall(env, emacs.intern(env, "symbol-name"), &.{head});
        if (emacs.pendingExit(env)) return error.PendingLispSignal;
        const name = try emacs.copyStringContents(env, arena, name_val);
        if (std.mem.eql(u8, name, "ctrl")) mods.ctrl = true;
        if (std.mem.eql(u8, name, "alt")) mods.alt = true;
        if (std.mem.eql(u8, name, "shift")) mods.shift = true;
        cur = emacs.funcall(env, emacs.intern(env, "cdr"), &.{cur});
        if (emacs.pendingExit(env)) return error.PendingLispSignal;
    }
    return mods;
}

// ---------------------------------------------------------------------
// spectreshell--create / --feed / --resize / --encode-key / --encode-paste
// / --encode-mouse / --release の実装本体
// ---------------------------------------------------------------------

fn createImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const rows = try extractDim(env, args[0]);
    const cols = try extractDim(env, args[1]);
    const term = try core.Term.init(term_alloc, rows, cols);
    return emacs.makeUserPtr(env, &termFinalizer, term);
}

fn feedImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const term = try getTerm(env, args[0]);

    var arena = scratchArena();
    defer arena.deinit();
    const a = arena.allocator();

    const bytes = try emacs.copyStringContents(env, a, args[1]);
    const update = try term.feed(a, bytes);
    return buildUpdatePlist(env, a, &update);
}

fn resizeImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const term = try getTerm(env, args[0]);
    const rows = try extractDim(env, args[1]);
    const cols = try extractDim(env, args[2]);

    var arena = scratchArena();
    defer arena.deinit();
    const a = arena.allocator();

    const update = try term.resize(a, rows, cols);
    return buildUpdatePlist(env, a, &update);
}

fn encodeKeyImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const term = try getTerm(env, args[0]);

    var arena = scratchArena();
    defer arena.deinit();
    const a = arena.allocator();

    const event = try buildKeyEvent(env, a, args[1], args[2]);
    const bytes = try term.encodeKey(a, event);
    if (bytes) |b| return emacs.makeUnibyteString(env, b);
    return emacs.nilv(env);
}

fn encodePasteImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const term = try getTerm(env, args[0]);

    var arena = scratchArena();
    defer arena.deinit();
    const a = arena.allocator();

    const text = try emacs.copyStringContents(env, a, args[1]);
    const bytes = try term.encodePaste(a, text);
    return emacs.makeUnibyteString(env, bytes);
}

fn encodeMouseImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    const term = try getTerm(env, args[0]);

    var arena = scratchArena();
    defer arena.deinit();
    const a = arena.allocator();

    const button = try buildMouseButton(env, a, args[1]);
    const action = try buildMouseAction(env, a, args[2]);
    const row = try extractCoord(env, args[3]);
    const col = try extractCoord(env, args[4]);
    const mods = try collectMouseMods(env, a, args[5]);

    const bytes = try term.encodeMouse(a, button, action, row, col, mods);
    if (bytes) |b| return emacs.makeUnibyteString(env, b);
    return emacs.nilv(env);
}

/// 二重解放safe: 既に解放済み (get_user_ptr が null) なら何もしない。
/// finalizer と共存できるよう、解放後は set_user_ptr で null にしておき
/// GC 時の finalizer 呼び出しが no-op になるようにする。
fn releaseImpl(env: *emacs.Env, args: []const *emacs.Value) !*emacs.Value {
    try checkTermType(env, args[0]);
    if (emacs.getUserPtr(env, args[0])) |ptr| {
        const term: *core.Term = @ptrCast(@alignCast(ptr));
        term.deinit();
        emacs.setUserPtr(env, args[0], null);
    }
    return emacs.nilv(env);
}

// ---------------------------------------------------------------------
// emacs_function ラッパー登録
// ---------------------------------------------------------------------

fn createFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, createImpl(env, args[0..@intCast(nargs)]));
}

fn feedFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, feedImpl(env, args[0..@intCast(nargs)]));
}

fn resizeFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, resizeImpl(env, args[0..@intCast(nargs)]));
}

fn encodeKeyFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, encodeKeyImpl(env, args[0..@intCast(nargs)]));
}

fn encodePasteFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, encodePasteImpl(env, args[0..@intCast(nargs)]));
}

fn encodeMouseFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, encodeMouseImpl(env, args[0..@intCast(nargs)]));
}

fn releaseFn(env: *emacs.Env, nargs: isize, args: [*]*emacs.Value, data: ?*anyopaque) callconv(.c) *emacs.Value {
    _ = data;
    return finish(env, releaseImpl(env, args[0..@intCast(nargs)]));
}

fn defalias(
    env: *emacs.Env,
    name: [:0]const u8,
    min_arity: isize,
    max_arity: isize,
    func: emacs.LispFunction,
    doc: [:0]const u8,
) void {
    const fn_val = emacs.makeFunction(env, min_arity, max_arity, func, doc, null);
    _ = emacs.funcall(env, emacs.intern(env, "defalias"), &.{ emacs.intern(env, name), fn_val });
}

/// signal は未知のシンボルに対して "Invalid error symbol" になり
/// 呼び出し側で condition-case を書けない (署名文字列が cryptic なだけで
/// 実害はないが型として捕まえられないのは design.org の要件から外れる)。
/// そのため独自シグナルは define-error で 'error の子として登録しておく。
fn defineError(env: *emacs.Env, symbol: [:0]const u8, message: []const u8) void {
    _ = emacs.funcall(env, emacs.intern(env, "define-error"), &.{
        emacs.intern(env, symbol),
        emacs.makeString(env, message),
        emacs.intern(env, "error"),
    });
}

pub fn registerAll(env: *emacs.Env) void {
    defineError(env, "spectreshell-terminal-released", "Spectreshell terminal has already been released");

    defalias(env, "spectreshell--create", 2, 2, createFn, "Create a ROWS x COLS spectreshell terminal object.");
    defalias(env, "spectreshell--feed", 2, 2, feedFn, "Feed BYTES to TERM and return the update plist.");
    defalias(env, "spectreshell--resize", 3, 3, resizeFn, "Resize TERM to ROWS x COLS and return the update plist.");
    defalias(env, "spectreshell--encode-key", 3, 3, encodeKeyFn, "Encode KEY with MODIFIERS for TERM into PTY bytes.");
    defalias(env, "spectreshell--encode-paste", 2, 2, encodePasteFn, "Encode TEXT as a paste for TERM into PTY bytes.");
    defalias(env, "spectreshell--encode-mouse", 6, 6, encodeMouseFn, "Encode a mouse BUTTON/ACTION at ROW/COL with MODIFIERS for TERM.");
    defalias(env, "spectreshell--release", 1, 1, releaseFn, "Explicitly release TERM. Safe to call more than once.");
}
