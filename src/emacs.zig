const std = @import("std");
const builtin = @import("builtin");

// Env の vtable レイアウト (特に Timespec の i64/i64 決め打ち) は 64bit
// の Linux/macOS でのみ検証済み。それ以外のターゲットでは extract_time
// 以降のフィールドオフセットがずれ、リンクは通っても実行時に即クラッシュ
// するため、ビルド時点で明示的に弾く。
comptime {
    const os = builtin.target.os.tag;
    if (@sizeOf(usize) != 8 or !(os == .linux or os.isDarwin())) {
        @compileError("spectreshell: emacs.Env layout is only verified for 64-bit Linux/macOS targets");
    }
}

/// emacs-module.h の struct emacs_value_tag* に対応する不透明ポインタ。
/// ヘッダの警告どおり NULL を「無効値」の目印として使わないため、
/// 借用ポインタも戻り値もすべて非 optional の *Value として扱う。
pub const Value = opaque {};

/// enum emacs_funcall_exit。C の enum はデフォルトで int 幅になるため
/// c_int で backing する。
pub const FuncallExit = enum(c_int) {
    ok = 0,
    signal = 1,
    throw = 2,
};

/// enum emacs_process_input_result。Phase 2 では未使用だが、Env 構造体の
/// レイアウトを崩さないためフィールドとして残す。
pub const ProcessInputResult = enum(c_int) {
    @"continue" = 0,
    quit = 1,
};

/// struct timespec (Linux x86_64/aarch64)。extract_time/make_time は
/// 未使用だが、後続フィールド (make_unibyte_string 等) のオフセットを
/// 保つために正しいサイズで宣言する。
pub const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: i64,
};

pub const Finalizer = *const fn (data: ?*anyopaque) callconv(.c) void;
pub const LispFunction = *const fn (
    env: *Env,
    nargs: isize,
    args: [*]*Value,
    data: ?*anyopaque,
) callconv(.c) *Value;

/// emacs_module_init に渡される struct emacs_runtime。
pub const Runtime = extern struct {
    size: isize,
    private_members: ?*anyopaque,
    get_environment: ?*const fn (*Runtime) callconv(.c) *Env,
};

/// struct emacs_env_31 (typedef emacs_env)。フィールドの順序と型は
/// /nix/store/.../include/emacs-module.h と完全一致させる。vtable なので
/// 1 つでもずれるとクラッシュする。Emacs 31 のみ対象のため env_25〜30 の
/// 差分は考慮しない。
pub const Env = extern struct {
    size: isize,
    private_members: ?*anyopaque,

    make_global_ref: ?*const fn (*Env, *Value) callconv(.c) *Value,
    free_global_ref: ?*const fn (*Env, *Value) callconv(.c) void,

    non_local_exit_check: ?*const fn (*Env) callconv(.c) FuncallExit,
    non_local_exit_clear: ?*const fn (*Env) callconv(.c) void,
    non_local_exit_get: ?*const fn (*Env, **Value, **Value) callconv(.c) FuncallExit,
    non_local_exit_signal: ?*const fn (*Env, *Value, *Value) callconv(.c) void,
    non_local_exit_throw: ?*const fn (*Env, *Value, *Value) callconv(.c) void,

    make_function: ?*const fn (
        *Env,
        isize,
        isize,
        LispFunction,
        ?[*:0]const u8,
        ?*anyopaque,
    ) callconv(.c) *Value,

    funcall: ?*const fn (*Env, *Value, isize, [*]*Value) callconv(.c) *Value,

    intern: ?*const fn (*Env, [*:0]const u8) callconv(.c) *Value,

    type_of: ?*const fn (*Env, *Value) callconv(.c) *Value,

    is_not_nil: ?*const fn (*Env, *Value) callconv(.c) bool,
    eq: ?*const fn (*Env, *Value, *Value) callconv(.c) bool,

    extract_integer: ?*const fn (*Env, *Value) callconv(.c) i64,
    make_integer: ?*const fn (*Env, i64) callconv(.c) *Value,

    extract_float: ?*const fn (*Env, *Value) callconv(.c) f64,
    make_float: ?*const fn (*Env, f64) callconv(.c) *Value,

    copy_string_contents: ?*const fn (*Env, *Value, ?[*]u8, *isize) callconv(.c) bool,
    make_string: ?*const fn (*Env, [*]const u8, isize) callconv(.c) *Value,

    make_user_ptr: ?*const fn (*Env, ?Finalizer, ?*anyopaque) callconv(.c) *Value,
    get_user_ptr: ?*const fn (*Env, *Value) callconv(.c) ?*anyopaque,
    set_user_ptr: ?*const fn (*Env, *Value, ?*anyopaque) callconv(.c) void,

    get_user_finalizer: ?*const fn (*Env, *Value) callconv(.c) ?Finalizer,
    set_user_finalizer: ?*const fn (*Env, *Value, ?Finalizer) callconv(.c) void,

    vec_get: ?*const fn (*Env, *Value, isize) callconv(.c) *Value,
    vec_set: ?*const fn (*Env, *Value, isize, *Value) callconv(.c) void,
    vec_size: ?*const fn (*Env, *Value) callconv(.c) isize,

    should_quit: ?*const fn (*Env) callconv(.c) bool,

    process_input: ?*const fn (*Env) callconv(.c) ProcessInputResult,

    extract_time: ?*const fn (*Env, *Value) callconv(.c) Timespec,
    make_time: ?*const fn (*Env, Timespec) callconv(.c) *Value,

    extract_big_integer: ?*const fn (*Env, *Value, ?*c_int, ?*isize, ?[*]usize) callconv(.c) bool,
    make_big_integer: ?*const fn (*Env, c_int, isize, ?[*]const usize) callconv(.c) *Value,

    get_function_finalizer: ?*const fn (*Env, *Value) callconv(.c) ?Finalizer,
    set_function_finalizer: ?*const fn (*Env, *Value, ?Finalizer) callconv(.c) void,

    open_channel: ?*const fn (*Env, *Value) callconv(.c) c_int,

    make_interactive: ?*const fn (*Env, *Value, *Value) callconv(.c) void,

    make_unibyte_string: ?*const fn (*Env, [*]const u8, isize) callconv(.c) *Value,
};

/// 呼び出し済みの env 関数が non-local exit を積んだかどうかを確認する。
/// extract_integer/copy_string_contents 等は型不一致時に自前で
/// wrong-type-argument を signal するため、以降の処理を続けず速やかに
/// Zig 側へエラーとして伝播させる必要がある。
pub fn pendingExit(env: *Env) bool {
    return env.non_local_exit_check.?(env) != .ok;
}

pub fn nonLocalExitSignal(env: *Env, symbol: *Value, data: *Value) void {
    env.non_local_exit_signal.?(env, symbol, data);
}

pub fn intern(env: *Env, name: [:0]const u8) *Value {
    return env.intern.?(env, name.ptr);
}

pub fn nilv(env: *Env) *Value {
    return intern(env, "nil");
}

pub fn t(env: *Env) *Value {
    return intern(env, "t");
}

pub fn typeOf(env: *Env, value: *Value) *Value {
    return env.type_of.?(env, value);
}

pub fn eq(env: *Env, a: *Value, b: *Value) bool {
    return env.eq.?(env, a, b);
}

pub fn isNotNil(env: *Env, value: *Value) bool {
    return env.is_not_nil.?(env, value);
}

pub fn makeInteger(env: *Env, n: i64) *Value {
    return env.make_integer.?(env, n);
}

/// 呼び出し元が args[i] に整数以外を渡した場合、extract_integer 自体が
/// wrong-type-argument を signal するため、戻り値を使わず pendingExit で
/// 検知する契約にしてある。
pub fn extractInteger(env: *Env, value: *Value) i64 {
    return env.extract_integer.?(env, value);
}

pub fn makeString(env: *Env, s: []const u8) *Value {
    return env.make_string.?(env, s.ptr, @intCast(s.len));
}

pub fn makeUnibyteString(env: *Env, s: []const u8) *Value {
    return env.make_unibyte_string.?(env, s.ptr, @intCast(s.len));
}

/// copy_string_contents は「必要サイズ問い合わせ→本コピー」の 2 段呼び出し
/// が仕様。SIZE には終端 NUL を含むため、返すスライスは len-1。
///
/// 契約: 返り値は len バイト確保した領域の先頭 len-1 バイトのサブスライス
/// なので、alloc.free で個別解放してはならない (長さ不一致で illegal
/// behavior になる)。呼び出し側は arena を渡して arena ごと破棄すること。
pub fn copyStringContents(env: *Env, alloc: std.mem.Allocator, value: *Value) ![]u8 {
    var len: isize = 0;
    _ = env.copy_string_contents.?(env, value, null, &len);
    if (pendingExit(env)) return error.PendingLispSignal;
    if (len <= 0) return &.{};

    const buf = try alloc.alloc(u8, @intCast(len));
    _ = env.copy_string_contents.?(env, value, buf.ptr, &len);
    if (pendingExit(env)) return error.PendingLispSignal;

    return buf[0..@intCast(len - 1)];
}

pub fn makeUserPtr(env: *Env, fin: Finalizer, ptr: *anyopaque) *Value {
    return env.make_user_ptr.?(env, fin, ptr);
}

pub fn getUserPtr(env: *Env, value: *Value) ?*anyopaque {
    return env.get_user_ptr.?(env, value);
}

pub fn setUserPtr(env: *Env, value: *Value, ptr: ?*anyopaque) void {
    env.set_user_ptr.?(env, value, ptr);
}

pub fn getUserFinalizer(env: *Env, value: *Value) ?Finalizer {
    return env.get_user_finalizer.?(env, value);
}

pub fn makeFunction(
    env: *Env,
    min_arity: isize,
    max_arity: isize,
    func: LispFunction,
    doc: ?[:0]const u8,
    data: ?*anyopaque,
) *Value {
    const doc_ptr: ?[*:0]const u8 = if (doc) |d| d.ptr else null;
    return env.make_function.?(env, min_arity, max_arity, func, doc_ptr, data);
}

pub fn funcall(env: *Env, func: *Value, args: []const *Value) *Value {
    return env.funcall.?(env, func, @intCast(args.len), @constCast(args.ptr));
}

pub fn cons(env: *Env, car: *Value, cdr: *Value) *Value {
    return funcall(env, intern(env, "cons"), &.{ car, cdr });
}

pub fn list(env: *Env, items: []const *Value) *Value {
    return funcall(env, intern(env, "list"), items);
}

pub fn signalWrongType(env: *Env, predicate: [:0]const u8, value: *Value) void {
    nonLocalExitSignal(env, intern(env, "wrong-type-argument"), list(env, &.{ intern(env, predicate), value }));
}

pub fn signalError(env: *Env, message: []const u8) void {
    nonLocalExitSignal(env, intern(env, "error"), list(env, &.{makeString(env, message)}));
}

// vtable の並びが 1 つでもずれるとリンク自体は通っても即クラッシュに
// なるため、フィールド数とサイズを回帰的にチェックする。
test "Env のフィールド数とサイズが emacs-module.h の struct emacs_env_31 と一致する" {
    // size(1) + private_members(1) + 関数ポインタ38個 = 40 フィールド、
    // すべてポインタ幅 (8 バイト) なのでパディングなしで 320 バイトになる。
    try std.testing.expectEqual(@as(usize, 320), @sizeOf(Env));
    try std.testing.expectEqual(@as(usize, 88), @offsetOf(Env, "intern"));
    try std.testing.expectEqual(@as(usize, 160), @offsetOf(Env, "make_string"));
    try std.testing.expectEqual(@as(usize, 312), @offsetOf(Env, "make_unibyte_string"));
}

test "Runtime のフィールドサイズが struct emacs_runtime と一致する" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Runtime));
}
