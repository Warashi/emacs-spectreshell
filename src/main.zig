const std = @import("std");
const emacs = @import("emacs.zig");
const module = @import("module.zig");

/// Emacs はこのシンボルの存在をもって GPL 互換モジュールと判定する。
/// 値は参照されないため 0 でよい。
export var plugin_is_GPL_compatible: c_int = 0;

/// モジュール初期化。0 を返すと Emacs 側で load 成功扱いになる。
export fn emacs_module_init(runtime: *emacs.Runtime) callconv(.c) c_int {
    return initImpl(runtime);
}

/// runtime/env の size フィールドはロード先 Emacs が実際に提供する構造体
/// の大きさ。emacs.Env は Emacs 31 の emacs_env_31 全体を宣言している
/// ため、それより小さい env を持つ古い Emacs にロードされた場合は末尾の
/// 関数ポインタ (make_unibyte_string 等) が構造体の外を指す。呼び出した
/// 瞬間に Emacs ごとクラッシュするので、登録前にサイズで弾いて
/// ロード失敗 (非 0) にする (emacs-module.h ドキュメント推奨の手順)。
fn initImpl(runtime: *emacs.Runtime) c_int {
    if (runtime.size < @sizeOf(emacs.Runtime)) return 1;
    const env = runtime.get_environment.?(runtime);
    if (env.size < @sizeOf(emacs.Env)) return 2;
    module.registerAll(env);
    return 0;
}

test "runtime が小さすぎる場合は初期化を拒否する" {
    var runtime: emacs.Runtime = .{
        .size = @sizeOf(emacs.Runtime) - 1,
        .private_members = null,
        .get_environment = null,
    };
    try std.testing.expectEqual(@as(c_int, 1), initImpl(&runtime));
}

test "env が小さすぎる場合は初期化を拒否する" {
    const stub = struct {
        var env: emacs.Env = undefined;
        fn getEnvironment(_: *emacs.Runtime) callconv(.c) *emacs.Env {
            return &env;
        }
    };
    stub.env.size = @sizeOf(emacs.Env) - 1;
    var runtime: emacs.Runtime = .{
        .size = @sizeOf(emacs.Runtime),
        .private_members = null,
        .get_environment = &stub.getEnvironment,
    };
    try std.testing.expectEqual(@as(c_int, 2), initImpl(&runtime));
}

test "ghostty-vt モジュールを import できる" {
    const vt = @import("ghostty-vt");
    _ = vt.Terminal;
}

test {
    _ = @import("core.zig");
    _ = @import("keymap.zig");
    _ = @import("emacs.zig");
    _ = @import("module.zig");
}
