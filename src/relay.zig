const std = @import("std");

/// 子が外側の端末へ向けて出したもの。spectreshell の画面には何も描かず、
/// Elisp がそのまま外側の tty へ中継する (docs/issues.org M-23)。
pub const Event = union(enum) {
    clipboard: Clipboard,
    notification: Notification,
    progress: Progress,
    bell,

    pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .clipboard => |c| alloc.free(c.data),
            .notification => |n| n.deinit(alloc),
            .progress, .bell => {},
        }
        self.* = undefined;
    }

    fn clone(self: Event, alloc: std.mem.Allocator) !Event {
        return switch (self) {
            .clipboard => |c| .{ .clipboard = .{ .kind = c.kind, .data = try alloc.dupe(u8, c.data) } },
            .notification => |n| .{ .notification = try Notification.init(alloc, n.title, n.body) },
            .progress, .bell => self,
        };
    }
};

/// OSC 52 の書き込み。DATA は子が送った base64 のまま。
pub const Clipboard = struct {
    kind: u8,
    data: []u8,
};

/// OSC 777 / OSC 9 の通知。OSC 9 には TITLE が無いので空になる。
pub const Notification = struct {
    title: []u8,
    body: []u8,

    pub fn init(alloc: std.mem.Allocator, title: []const u8, body: []const u8) !Notification {
        const owned_title = try alloc.dupe(u8, title);
        errdefer alloc.free(owned_title);
        return .{ .title = owned_title, .body = try alloc.dupe(u8, body) };
    }

    pub fn deinit(self: Notification, alloc: std.mem.Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
    }
};

/// OSC 9;4 の進捗。STATE は OSC 9;4 の番号 (0 消去・1 設定・2 エラー・
/// 3 不定・4 一時停止)。
pub const Progress = struct {
    state: u8,
    value: ?u8,
};

pub fn deinitAll(alloc: std.mem.Allocator, events: []Event) void {
    for (events) |*e| e.deinit(alloc);
    alloc.free(events);
}

/// PENDING (FROM で確保) を TO に写して返し、PENDING を空にする。Term と
/// Update で確保元が違う (Update は呼び出しごとの arena) ので移さず写す。
/// 失敗したときは PENDING をそのまま残す。
pub fn take(pending: *std.ArrayList(Event), from: std.mem.Allocator, to: std.mem.Allocator) ![]Event {
    const events = try to.alloc(Event, pending.items.len);
    var copied: usize = 0;
    errdefer {
        for (events[0..copied]) |*e| e.deinit(to);
        to.free(events);
    }
    for (pending.items) |e| {
        events[copied] = try e.clone(to);
        copied += 1;
    }
    for (pending.items) |*e| e.deinit(from);
    pending.clearRetainingCapacity();
    return events;
}

test "take は確保元を移して保留を空にする" {
    const alloc = std.testing.allocator;
    var pending: std.ArrayList(Event) = .empty;
    defer pending.deinit(alloc);
    try pending.append(alloc, .{ .clipboard = .{ .kind = 'c', .data = try alloc.dupe(u8, "aGk=") } });

    const events = try take(&pending, alloc, alloc);
    defer deinitAll(alloc, events);
    try std.testing.expectEqual(@as(usize, 0), pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("aGk=", events[0].clipboard.data);
}

test "take は写す途中で失敗しても保留を残しリークしない" {
    var pending: std.ArrayList(Event) = .empty;
    defer {
        for (pending.items) |*e| e.deinit(std.testing.allocator);
        pending.deinit(std.testing.allocator);
    }
    try pending.append(std.testing.allocator, .{ .clipboard = .{ .kind = 'c', .data = try std.testing.allocator.dupe(u8, "aGk=") } });
    try pending.append(std.testing.allocator, .{ .clipboard = .{ .kind = 'p', .data = try std.testing.allocator.dupe(u8, "eW8=") } });

    // fail_index=2: スライスと 1 件目の dupe は成功し、2 件目の dupe で失敗する。
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, take(&pending, std.testing.allocator, failing.allocator()));
    try std.testing.expectEqual(@as(usize, 2), pending.items.len);
}
