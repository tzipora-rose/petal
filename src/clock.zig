//! Time: local timestamps with their UTC offset for the log and replies, and a monotonic clock
//! for durations and timeouts.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");

/// Milliseconds on a clock that never goes backwards.
pub fn ms() u64 {
    var count: i64 = 0;
    var frequency: i64 = 1;
    _ = win.QueryPerformanceCounter(&count);
    _ = win.QueryPerformanceFrequency(&frequency);
    return @intCast(@divTrunc(@as(i128, count) * 1000, frequency));
}

pub const Stamp = struct {
    local: win.SYSTEMTIME,
    offset_minutes: i32,

    /// "2026-10-01T07:15:02.123-04:00"
    pub fn iso(s: Stamp, a: text.Allocator) []u8 {
        const t = s.local;
        const sign: u8 = if (s.offset_minutes < 0) '-' else '+';
        const off: u32 = @abs(s.offset_minutes);
        return text.print(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{c}{d:0>2}:{d:0>2}", .{ t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, t.wMilliseconds, sign, off / 60, off % 60 });
    }

    /// "07:15:02"
    pub fn clock(s: Stamp, a: text.Allocator) []u8 {
        const t = s.local;
        return text.print(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.wHour, t.wMinute, t.wSecond });
    }
};

pub fn stamp() Stamp {
    var utc: win.SYSTEMTIME = undefined;
    var local: win.SYSTEMTIME = undefined;
    win.GetSystemTime(&utc);
    win.GetLocalTime(&local);
    return .{ .local = local, .offset_minutes = offsetMinutes(local, utc) };
}

// The two readings are a moment apart, so the difference is rounded to the nearest quarter hour,
// a step every real UTC offset is a multiple of.
fn offsetMinutes(local: win.SYSTEMTIME, utc: win.SYSTEMTIME) i32 {
    var a: std.os.windows.FILETIME = undefined;
    var b: std.os.windows.FILETIME = undefined;
    if (!win.SystemTimeToFileTime(&local, &a).toBool() or !win.SystemTimeToFileTime(&utc, &b).toBool()) return 0;
    const la: i64 = @bitCast((@as(u64, a.dwHighDateTime) << 32) | a.dwLowDateTime);
    const lb: i64 = @bitCast((@as(u64, b.dwHighDateTime) << 32) | b.dwLowDateTime);
    const minutes = @as(f64, @floatFromInt(la - lb)) / (10_000_000.0 * 60.0);
    return @as(i32, @intFromFloat(@round(minutes / 15.0))) * 15;
}

test "offset rounding" {
    var local = std.mem.zeroes(win.SYSTEMTIME);
    local = .{ .wYear = 2026, .wMonth = 10, .wDayOfWeek = 4, .wDay = 1, .wHour = 7, .wMinute = 15, .wSecond = 2, .wMilliseconds = 900 };
    var utc = local;
    utc.wHour = 11;
    utc.wMilliseconds = 905;
    try std.testing.expectEqual(@as(i32, -240), offsetMinutes(local, utc));
    const s = Stamp{ .local = local, .offset_minutes = -240 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("2026-10-01T07:15:02.900-04:00", s.iso(arena.allocator()));
    try std.testing.expectEqualStrings("07:15:02", s.clock(arena.allocator()));
}
