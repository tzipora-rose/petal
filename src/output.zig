//! petal's standard output, which carries nothing but MCP messages: one JSON-RPC message per line.
//! Several threads answer calls at once, so each message is written whole under a lock.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");

const Allocator = text.Allocator;

pub const Output = struct {
    handle: ?win.HANDLE,
    lock: win.SRWLOCK = .{},

    pub fn init() Output {
        const h = win.GetStdHandle(win.STD_OUTPUT_HANDLE);
        return .{ .handle = if (h == win.INVALID_HANDLE_VALUE) null else h };
    }

    pub fn send(o: *Output, message: []const u8) void {
        const h = o.handle orelse return;
        win.AcquireSRWLockExclusive(&o.lock);
        defer win.ReleaseSRWLockExclusive(&o.lock);
        for ([_][]const u8{ message, "\n" }) |part| {
            var at: usize = 0;
            while (at < part.len) {
                var n: win.DWORD = 0;
                if (!win.WriteFile(h, part[at..].ptr, @intCast(part.len - at), &n, null).toBool() or n == 0) return;
                at += n;
            }
        }
    }

    pub fn result(o: *Output, a: Allocator, id_json: []const u8, result_json: []const u8) void {
        o.send(text.concat(a, &.{ "{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"result\":", result_json, "}" }));
    }

    pub fn failure(o: *Output, a: Allocator, id_json: []const u8, code: i32, message: []const u8) void {
        o.send(text.concat(a, &.{ "{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"error\":{\"code\":", text.print(a, "{d}", .{code}), ",\"message\":", json(a, message), "}}" }));
    }

    pub fn notify(o: *Output, a: Allocator, method: []const u8, params_json: []const u8) void {
        o.send(text.concat(a, &.{ "{\"jsonrpc\":\"2.0\",\"method\":", json(a, method), ",\"params\":", params_json, "}" }));
    }
};

/// Any value as JSON text, every string in it made valid UTF-8 first: std.json writes a string
/// that is not as an array of byte values, which no reader takes for text.
pub fn json(a: Allocator, value: anytype) []u8 {
    const T = @TypeOf(value);
    if (T == []const u8 or T == []u8) return stringify(a, text.validUtf8(a, value));
    if (T == ?[]const u8 or T == ?[]u8) return stringify(a, if (value) |s| text.validUtf8(a, s) else null);
    if (T == std.json.Value) return stringify(a, validValue(a, value));
    return stringify(a, value);
}

fn stringify(a: Allocator, value: anytype) []u8 {
    return std.json.Stringify.valueAlloc(a, value, .{}) catch text.outOfMemory();
}

fn validValue(a: Allocator, v: std.json.Value) std.json.Value {
    switch (v) {
        .string => |s| return .{ .string = text.validUtf8(a, s) },
        .number_string => |s| return .{ .number_string = text.validUtf8(a, s) },
        .array => |items| {
            var copy = std.json.Array.initCapacity(a, items.items.len) catch text.outOfMemory();
            for (items.items) |item| copy.appendAssumeCapacity(validValue(a, item));
            return .{ .array = copy };
        },
        .object => |fields| {
            var copy: std.json.ObjectMap = .empty;
            var it = fields.iterator();
            while (it.next()) |field| copy.put(a, text.validUtf8(a, field.key_ptr.*), validValue(a, field.value_ptr.*)) catch text.outOfMemory();
            return .{ .object = copy };
        },
        else => return v,
    }
}

test json {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\"a\\\"b\\n\"", json(a, @as([]const u8, "a\"b\n")));
    try std.testing.expectEqualStrings("\"bad \u{FFFD} byte\"", json(a, @as([]const u8, "bad \x82 byte")));
    try std.testing.expectEqualStrings("null", json(a, @as(?[]const u8, null)));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":\"x\",\"list\":[\"y\"]}", .{});
    var value = parsed;
    try value.object.put(a, "command", .{ .string = "x \xed\xa0\x80" });
    try std.testing.expectEqualStrings("{\"command\":\"x \u{FFFD}\u{FFFD}\u{FFFD}\",\"list\":[\"y\"]}", json(a, value));
}

test {
    std.testing.refAllDecls(@This());
}
