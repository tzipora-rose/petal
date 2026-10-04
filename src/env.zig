//! Environment blocks for the shells petal starts: petal's own environment or a copy of another
//! shell's, with petal's few additions, in the form CreateProcessW takes.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");

const Allocator = text.Allocator;

/// Variables as "NAME=VALUE" UTF-16 strings, held in `a`. A name may itself start with "="
/// ("=C:=C:\x").
pub const Env = struct {
    a: Allocator,
    entries: std.ArrayList([]u16) = .empty,

    pub fn fromProcess(a: Allocator) Env {
        var env: Env = .{ .a = a };
        const strings = win.GetEnvironmentStringsW() orelse return env;
        defer _ = win.FreeEnvironmentStringsW(strings);
        var i: usize = 0;
        while (strings[i] != 0) {
            const start = i;
            while (strings[i] != 0) i += 1;
            env.entries.append(a, a.dupe(u16, strings[start..i]) catch text.outOfMemory()) catch text.outOfMemory();
            i += 1;
        }
        return env;
    }

    /// From a PowerShell shell's snapshot: "NAME=VALUE" entries in UTF-8, each ending in a NUL.
    pub fn fromSnapshot(a: Allocator, snapshot: []const u8) Env {
        var env: Env = .{ .a = a };
        var it = std.mem.splitScalar(u8, snapshot, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            const w = text.wide(a, entry);
            env.entries.append(a, w[0..w.len]) catch text.outOfMemory();
        }
        return env;
    }

    pub fn clone(e: *const Env, a: Allocator) Env {
        var env: Env = .{ .a = a };
        for (e.entries.items) |entry| env.entries.append(a, a.dupe(u16, entry) catch text.outOfMemory()) catch text.outOfMemory();
        return env;
    }

    pub fn get(e: *const Env, name: []const u8) ?[]const u16 {
        var buffer: [256]u16 = undefined;
        const w = asciiWide(&buffer, name);
        for (e.entries.items) |entry| {
            if (sameName(nameOf(entry), w)) return entry[nameOf(entry).len + 1 ..];
        }
        return null;
    }

    pub fn set(e: *Env, name: []const u8, value: []const u8) void {
        e.remove(name);
        const entry = text.wide(e.a, text.concat(e.a, &.{ name, "=", value }));
        e.entries.append(e.a, entry[0..entry.len]) catch text.outOfMemory();
    }

    pub fn setWide(e: *Env, name: []const u8, value: []const u16) void {
        e.remove(name);
        var buffer: [256]u16 = undefined;
        const entry = std.mem.concat(e.a, u16, &.{ asciiWide(&buffer, name), &[_]u16{'='}, value }) catch text.outOfMemory();
        e.entries.append(e.a, entry) catch text.outOfMemory();
    }

    pub fn remove(e: *Env, name: []const u8) void {
        var buffer: [256]u16 = undefined;
        const w = asciiWide(&buffer, name);
        var i: usize = 0;
        while (i < e.entries.items.len) {
            if (sameName(nameOf(e.entries.items[i]), w)) {
                _ = e.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// The block CreateProcessW takes with CREATE_UNICODE_ENVIRONMENT, sorted by name without
    /// regard to case, as Windows keeps its own.
    pub fn block(e: *Env) [:0]u16 {
        std.mem.sort([]u16, e.entries.items, {}, lessThan);
        var out: std.ArrayList(u16) = .empty;
        for (e.entries.items) |entry| {
            out.appendSlice(e.a, entry) catch text.outOfMemory();
            out.append(e.a, 0) catch text.outOfMemory();
        }
        if (e.entries.items.len == 0) out.append(e.a, 0) catch text.outOfMemory();
        out.append(e.a, 0) catch text.outOfMemory();
        const all = out.toOwnedSlice(e.a) catch text.outOfMemory();
        return all[0 .. all.len - 1 :0];
    }
};

/// The names petal sets and removes are plain ASCII, so they widen without allocating.
fn asciiWide(buffer: *[256]u16, name: []const u8) []const u16 {
    for (name, 0..) |c, i| buffer[i] = c;
    return buffer[0..name.len];
}

fn nameOf(entry: []const u16) []const u16 {
    const from: usize = if (entry.len > 0 and entry[0] == '=') 1 else 0;
    const eq = std.mem.findScalarPos(u16, entry, from, '=') orelse entry.len;
    return entry[0..eq];
}

fn upper(c: u16) u16 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn sameName(a: []const u16, b: []const u16) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (upper(x) != upper(y)) return false;
    return true;
}

fn lessThan(_: void, a: []u16, b: []u16) bool {
    const na = nameOf(a);
    const nb = nameOf(b);
    const n = @min(na.len, nb.len);
    for (na[0..n], nb[0..n]) |x, y| {
        if (upper(x) != upper(y)) return upper(x) < upper(y);
    }
    return na.len < nb.len;
}

test Env {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env.fromSnapshot(a, "Path=C:\\x\x00HOME=C:\\Users\\a\x00=C:=C:\\here\x00");
    env.set("PETAL_LOOP", "loop");
    env.set("path", "C:\\y");
    try std.testing.expectEqualSlices(u16, text.wide(a, "C:\\y"), env.get("PATH").?);
    env.remove("petal_loop");
    try std.testing.expect(env.get("PETAL_LOOP") == null);
    const b = env.block();
    const expected = text.wide(a, "=C:=C:\\here\x00HOME=C:\\Users\\a\x00path=C:\\y\x00");
    try std.testing.expectEqualSlices(u16, expected, b[0..b.len]);
    try std.testing.expectEqual(@as(u16, 0), b[b.len]);
}
