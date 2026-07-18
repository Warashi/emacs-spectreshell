const std = @import("std");

/// Emacs はこのシンボルの存在をもって GPL 互換モジュールと判定する。
/// 値は参照されないため 0 でよい。
export var plugin_is_GPL_compatible: c_int = 0;

/// emacs_module.h の struct emacs_runtime。Phase 0 では中身に触れないため
/// opaque で宣言し、フィールド定義は emacs-module 境界の実装時に追加する。
pub const EmacsRuntime = opaque {};

/// モジュール初期化。0 を返すと Emacs 側で load 成功扱いになる。
export fn emacs_module_init(runtime: ?*EmacsRuntime) callconv(.c) c_int {
    _ = runtime;
    return 0;
}

test "ghostty-vt モジュールを import できる" {
    const vt = @import("ghostty-vt");
    _ = vt.Terminal;
}

test {
    _ = @import("core.zig");
}
