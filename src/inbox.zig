//! Messages for the session's agents: each a UTF-8 text file ending in .msg in the session's inbox
//! folder. petal hands every waiting message over with its next reply, oldest name first, and moves
//! it into the inbox's delivered folder. A writer writes the message under another name first and
//! then renames it to .msg, so petal never reads half of one.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const paths = @import("paths.zig");

const Allocator = text.Allocator;

pub const Message = struct {
    name: []const u8,
    text: []const u8,
    /// Local time the file was last written, "07:15:02".
    sent: []const u8,
};

const message_limit = 256 * 1024;

pub fn take(a: Allocator, inbox: []const u8) []Message {
    var names: std.ArrayList([]u8) = .empty;
    var data: win.WIN32_FIND_DATAW = undefined;
    const find = win.FindFirstFileW(text.wide(a, paths.join(a, &.{ inbox, "*.msg" })).ptr, &data);
    if (find == win.INVALID_HANDLE_VALUE) return &.{};
    while (true) {
        if (data.dwFileAttributes & win.FILE_ATTRIBUTE_DIRECTORY == 0) {
            names.append(a, text.narrow(a, std.mem.sliceTo(&data.cFileName, 0))) catch text.outOfMemory();
        }
        if (!win.FindNextFileW(find, &data).toBool()) break;
    }
    _ = win.FindClose(find);
    std.mem.sort([]u8, names.items, {}, lessThan);

    const delivered = paths.join(a, &.{ inbox, "delivered" });
    _ = paths.makeDirs(a, delivered);
    var messages: std.ArrayList(Message) = .empty;
    for (names.items) |name| {
        const path = paths.join(a, &.{ inbox, name });
        const h = paths.openRead(a, path) orelse continue;
        const bytes = paths.readAll(a, h, message_limit);
        const sent = lastWritten(a, h);
        win.CloseHandle(h);
        // Whichever call moves the file delivers it; a call that loses the race skips it.
        const moved = win.MoveFileExW(text.wide(a, path).ptr, text.wide(a, paths.join(a, &.{ delivered, name })).ptr, win.MOVEFILE_REPLACE_EXISTING).toBool();
        if (!moved) continue;
        messages.append(a, .{ .name = name, .text = text.cleanOutput(a, stripBom(bytes)), .sent = sent }) catch text.outOfMemory();
    }
    return messages.items;
}

fn lessThan(_: void, x: []u8, y: []u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn stripBom(bytes: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes[3..] else bytes;
}

fn lastWritten(a: Allocator, h: win.HANDLE) []const u8 {
    var written: std.os.windows.FILETIME = undefined;
    if (!win.GetFileTime(h, null, null, &written).toBool()) return "?";
    var utc: win.SYSTEMTIME = undefined;
    var local: win.SYSTEMTIME = undefined;
    if (!win.FileTimeToSystemTime(&written, &utc).toBool()) return "?";
    if (!win.SystemTimeToTzSpecificLocalTime(null, &utc, &local).toBool()) return "?";
    return text.print(a, "{d:0>2}:{d:0>2}:{d:0>2}", .{ local.wHour, local.wMinute, local.wSecond });
}

test {
    std.testing.refAllDecls(@This());
}
