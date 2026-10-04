//! petal: an MCP server whose shells keep their state between calls.
//!
//! "petal" runs the server on standard input and output, as Claude Code starts it.
//! "petal hook" runs it as Claude Code's PreToolUse hook for petal's tools.
//! "petal version" prints its version.

const std = @import("std");
const win = @import("win.zig");
const tools = @import("tools.zig");
const server = @import("server.zig");
const hook = @import("hook.zig");

pub fn main(init: std.process.Init.Minimal) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const args = init.args.toSlice(arena.allocator()) catch win.ExitProcess(2);
    if (args.len < 2) server.serve();
    const what = args[1];
    if (std.mem.eql(u8, what, "hook")) hook.run();
    if (std.mem.eql(u8, what, "version") or std.mem.eql(u8, what, "--version")) {
        say(win.STD_OUTPUT_HANDLE, "petal " ++ tools.version ++ "\n");
        win.ExitProcess(0);
    }
    say(win.STD_ERROR_HANDLE, "usage: petal (the MCP server) | petal hook | petal version\n");
    win.ExitProcess(2);
}

fn say(which: win.DWORD, message: []const u8) void {
    const h = win.GetStdHandle(which) orelse return;
    var n: win.DWORD = 0;
    _ = win.WriteFile(h, message.ptr, @intCast(message.len), &n, null);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("bashcheck.zig");
    _ = @import("session.zig");
    _ = @import("shell.zig");
    _ = @import("env.zig");
    _ = @import("clock.zig");
    _ = @import("log.zig");
    _ = @import("output.zig");
    _ = @import("inbox.zig");
    _ = @import("paths.zig");
    _ = @import("text.zig");
    _ = @import("hook.zig");
    _ = @import("server.zig");
}
