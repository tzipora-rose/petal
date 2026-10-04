//! The session's log: one JSON object per line in log.jsonl in the session's folder, each with
//! the local time it was written. A command's full output is a file of its own, which a record
//! names.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");

const Allocator = text.Allocator;

const FILE_APPEND_DATA: win.DWORD = 0x4;

pub const Log = struct {
    handle: ?win.HANDLE,
    lock: win.SRWLOCK = .{},
    closed: bool = false,

    pub fn open(a: Allocator, path: []const u8) Log {
        const h = win.CreateFileW(text.wide(a, path).ptr, FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
        return .{ .handle = if (h == win.INVALID_HANDLE_VALUE) null else h };
    }

    /// Writes the record's fields after the time and the event's name.
    pub fn record(l: *Log, a: Allocator, event: []const u8, fields: Fields) void {
        l.write(a, event, fields, false);
    }

    /// Writes the log's last record: any record after it is not written.
    pub fn close(l: *Log, a: Allocator, event: []const u8, fields: Fields) void {
        l.write(a, event, fields, true);
    }

    fn write(l: *Log, a: Allocator, event: []const u8, fields: Fields, last: bool) void {
        const h = l.handle orelse return;
        const line = text.concat(a, &.{ "{\"time\":", json(a, clock.stamp().iso(a)), ",\"event\":", json(a, event), if (fields.out.items.len > 0) "," else "", fields.out.items, "}\n" });
        win.AcquireSRWLockExclusive(&l.lock);
        defer win.ReleaseSRWLockExclusive(&l.lock);
        if (l.closed) return;
        _ = paths.writeAll(h, line);
        if (last) l.closed = true;
    }
};

/// The members of a log record, in `a`.
pub const Fields = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn add(f: *Fields, name: []const u8, value: anytype) void {
        if (f.out.items.len > 0) f.out.append(f.a, ',') catch text.outOfMemory();
        f.out.appendSlice(f.a, json(f.a, name)) catch text.outOfMemory();
        f.out.append(f.a, ':') catch text.outOfMemory();
        f.out.appendSlice(f.a, json(f.a, value)) catch text.outOfMemory();
    }
};

const json = @import("output.zig").json;

test Fields {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var f: Fields = .{ .a = arena.allocator() };
    f.add("shell", @as([]const u8, "pwsh"));
    f.add("exit", @as(i64, 3));
    f.add("intended", false);
    f.add("from", @as(?[]const u8, null));
    try std.testing.expectEqualStrings("\"shell\":\"pwsh\",\"exit\":3,\"intended\":false,\"from\":null", f.out.items);
}

test {
    std.testing.refAllDecls(@This());
}
