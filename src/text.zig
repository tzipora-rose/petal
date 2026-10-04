//! Text helpers: conversions between UTF-8 and the UTF-16 Windows uses, and the clean-up petal
//! applies to a command's output before it goes back as JSON.
//!
//! A function that allocates takes the allocator as its first argument, `a`. Most memory belongs
//! to one call and is freed with that call's arena; what must outlast a call is copied into
//! `lasting` and freed when it is replaced.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

/// For what outlasts a call: shells, stamens, the session. Safe to use from any thread.
pub const lasting: Allocator = std.heap.smp_allocator;

/// UTF-8 (or WTF-8) to the NUL-terminated UTF-16 Windows functions take.
pub fn wide(a: Allocator, s: []const u8) [:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(a, s) catch outOfMemory();
}

/// UTF-16 from Windows to WTF-8, which keeps any unpaired surrogate a Windows name may hold.
pub fn narrow(a: Allocator, s: []const u16) []u8 {
    return std.unicode.wtf16LeToWtf8Alloc(a, s) catch outOfMemory();
}

pub fn dupe(a: Allocator, s: []const u8) []u8 {
    return a.dupe(u8, s) catch outOfMemory();
}

pub fn print(a: Allocator, comptime fmt: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a, fmt, args) catch outOfMemory();
}

pub fn concat(a: Allocator, parts: []const []const u8) []u8 {
    return std.mem.concat(a, u8, parts) catch outOfMemory();
}

/// Replaces a lasting string with a lasting copy of `new`, freeing the old one.
pub fn replace(field: *?[]const u8, new: ?[]const u8) void {
    if (field.*) |old| lasting.free(old);
    field.* = if (new) |n| dupe(lasting, n) else null;
}

pub fn outOfMemory() noreturn {
    @panic("petal: out of memory");
}

/// Bytes a program wrote, as valid UTF-8 (see `validUtf8`), with Windows line endings made "\n".
pub fn cleanOutput(a: Allocator, bytes: []const u8) []u8 {
    return repair(a, bytes, true);
}

/// The text as valid UTF-8: each byte that does not begin a valid UTF-8 sequence becomes U+FFFD.
/// Text that is already valid comes back as it is. JSON cannot carry anything else.
pub fn validUtf8(a: Allocator, s: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    return repair(a, s, false);
}

fn repair(a: Allocator, bytes: []const u8, crlf: bool) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, bytes.len) catch outOfMemory();
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (crlf and b == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
            i += 1;
            continue;
        }
        if (b < 0x80) {
            out.append(a, b) catch outOfMemory();
            i += 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            out.appendSlice(a, "\u{FFFD}") catch outOfMemory();
            i += 1;
            continue;
        };
        if (i + len > bytes.len) {
            out.appendSlice(a, "\u{FFFD}") catch outOfMemory();
            i += 1;
            continue;
        }
        _ = std.unicode.utf8Decode(bytes[i .. i + len]) catch {
            out.appendSlice(a, "\u{FFFD}") catch outOfMemory();
            i += 1;
            continue;
        };
        out.appendSlice(a, bytes[i .. i + len]) catch outOfMemory();
        i += len;
    }
    return out.toOwnedSlice(a) catch outOfMemory();
}

/// JSON text with each escape of a lone surrogate (a \u escape from D800 to DFFF that is not one
/// half of a pair) replaced by the escape of U+FFFD. JSON allows a lone surrogate, but Zig's parser
/// rejects the whole text, and a request petal cannot parse is one it cannot answer by its id.
pub fn pairSurrogates(a: Allocator, s: []const u8) []const u8 {
    const backslash = '\x5c';
    if (std.mem.find(u8, s, "\x5cu") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(a, s.len) catch outOfMemory();
    var changed = false;
    var in_string = false;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '"') {
            in_string = !in_string;
        } else if (in_string and c == backslash and i + 1 < s.len) {
            if (s[i + 1] == 'u') if (hexUnit(s, i + 2)) |unit| {
                if (unit >= 0xD800 and unit <= 0xDBFF and s.len >= i + 12 and s[i + 6] == backslash and s[i + 7] == 'u') {
                    if (hexUnit(s, i + 8)) |low| if (low >= 0xDC00 and low <= 0xDFFF) {
                        out.appendSlice(a, s[i .. i + 12]) catch outOfMemory();
                        i += 12;
                        continue;
                    };
                }
                if (unit >= 0xD800 and unit <= 0xDFFF) {
                    out.appendSlice(a, "\x5cufffd") catch outOfMemory();
                    changed = true;
                    i += 6;
                    continue;
                }
            };
            out.appendSlice(a, s[i .. i + 2]) catch outOfMemory();
            i += 2;
            continue;
        }
        out.append(a, c) catch outOfMemory();
        i += 1;
    }
    return if (changed) out.items else s;
}

fn hexUnit(s: []const u8, at: usize) ?u16 {
    if (at + 4 > s.len) return null;
    for (s[at .. at + 4]) |c| if (!std.ascii.isHex(c)) return null;
    return std.fmt.parseInt(u16, s[at .. at + 4], 16) catch null;
}

/// How many UTF-16 code units the UTF-8 text takes: the unit Claude Code counts characters in.
pub fn utf16Length(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        n += if (len == 4) 2 else 1;
        i += len;
    }
    return n;
}

/// The byte offset at which the first `units` UTF-16 code units of `s` end.
pub fn offsetOfUnits(s: []const u8, units: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const size: usize = if (len == 4) 2 else 1;
        if (n + size > units) break;
        n += size;
        i += len;
    }
    return i;
}

pub fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var n: usize = std.mem.count(u8, s, "\n");
    if (s[s.len - 1] != '\n') n += 1;
    return n;
}

/// The first line of a command, shortened for display.
pub fn firstLine(a: Allocator, s: []const u8, max: usize) []const u8 {
    const end = std.mem.findScalar(u8, s, '\n') orelse s.len;
    const line = std.mem.trimEnd(u8, s[0..end], "\r");
    if (utf16Length(line) <= max) return if (end < s.len) concat(a, &.{ line, " …" }) else line;
    return concat(a, &.{ line[0..offsetOfUnits(line, max)], "…" });
}

test cleanOutput {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "a\r\nb\r\n", "a\nb\n" },
        .{ "x\x82y", "x\u{FFFD}y" },
        .{ "é中😀", "é中😀" },
        .{ "\xe4", "\u{FFFD}" },
        .{ "\xed\xa0\x80", "\u{FFFD}\u{FFFD}\u{FFFD}" },
    };
    for (cases) |c| {
        const got = cleanOutput(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test pairSurrogates {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    const bs = "\x5c";
    // A lone high surrogate, a lone low one, a pair, and an escaped backslash before "ud800".
    const in = "{\"c\":\"a" ++ bs ++ "ud800b" ++ bs ++ "udc00c" ++ bs ++ "ud83d" ++ bs ++ "ude00d" ++ bs ++ bs ++ "ud800e\"}";
    const want = "{\"c\":\"a" ++ bs ++ "ufffdb" ++ bs ++ "ufffdc" ++ bs ++ "ud83d" ++ bs ++ "ude00d" ++ bs ++ bs ++ "ud800e\"}";
    try t.expect(if (std.json.parseFromSliceLeaky(std.json.Value, a, in, .{})) |_| false else |_| true);
    const repaired = pairSurrogates(a, in);
    try t.expectEqualStrings(want, repaired);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, repaired, .{});
    try t.expectEqualStrings("a\u{FFFD}b\u{FFFD}c\u{1F600}d" ++ bs ++ "ud800e", v.object.get("c").?.string);
    const plain = "{\"c\":\"x\"}";
    try t.expect(pairSurrogates(a, plain).ptr == plain.ptr);
}

test validUtf8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = "é中😀\r\n";
    try std.testing.expect(validUtf8(a, valid).ptr == valid.ptr);
    try std.testing.expectEqualStrings("x\u{FFFD}\r\n", validUtf8(a, "x\x82\r\n"));
    try std.testing.expectEqualStrings("\u{FFFD}\u{FFFD}\u{FFFD}", validUtf8(a, "\xed\xa0\x80"));
}

test utf16Length {
    try std.testing.expectEqual(@as(usize, 5), utf16Length("é中😀a"));
    try std.testing.expectEqual(@as(usize, 5), offsetOfUnits("é中😀a", 2));
    try std.testing.expectEqual(@as(usize, 5), offsetOfUnits("é中😀a", 3));
    try std.testing.expectEqual(@as(usize, 9), offsetOfUnits("é中😀a", 4));
}

test replace {
    var field: ?[]const u8 = null;
    replace(&field, "one");
    replace(&field, "two");
    try std.testing.expectEqualStrings("two", field.?);
    replace(&field, null);
    try std.testing.expect(field == null);
}
