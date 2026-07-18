const std = @import("std");
const emacs = @import("emacs.zig");
const module = @import("module.zig");

/// Emacs はこのシンボルの存在をもって GPL 互換モジュールと判定する。
/// 値は参照されないため 0 でよい。
export var plugin_is_GPL_compatible: c_int = 0;

/// モジュール初期化。0 を返すと Emacs 側で load 成功扱いになる。
export fn emacs_module_init(runtime: *emacs.Runtime) callconv(.c) c_int {
    const env = runtime.get_environment.?(runtime);
    module.registerAll(env);
    return 0;
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
