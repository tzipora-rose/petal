//! petal as Claude Code's PreToolUse hook for its own tools: it writes the calling agent's
//! identity into the call, so each agent gets its own shells without naming them. Claude Code
//! hands a hook agent_id only when the call comes from a subagent; the main agent is "main".
//! Whatever goes wrong, the hook prints nothing, which leaves the call as it was.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const paths = @import("paths.zig");

const Allocator = text.Allocator;

pub fn run() noreturn {
    const a = text.lasting;
    const stdin = win.GetStdHandle(win.STD_INPUT_HANDLE) orelse win.ExitProcess(0);
    const input = paths.readAll(a, stdin, 64 * 1024 * 1024);
    if (rewrite(a, input)) |output| {
        if (win.GetStdHandle(win.STD_OUTPUT_HANDLE)) |stdout| _ = paths.writeAll(stdout, output);
    }
    win.ExitProcess(0);
}

/// The hook's answer for one call, or null to leave the call as it was.
pub fn rewrite(a: Allocator, input: []const u8) ?[]const u8 {
    const bytes = if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input[3..] else input;
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch return null;
    if (parsed != .object) return null;
    const tool_input_value = parsed.object.getPtr("tool_input") orelse return null;
    if (tool_input_value.* != .object) return null;
    const tool_input = &tool_input_value.object;
    var agent: []const u8 = "main";
    var agent_type: ?[]const u8 = null;
    if (parsed.object.get("agent_id")) |v| if (v == .string and v.string.len > 0) {
        agent = v.string;
        if (parsed.object.get("agent_type")) |t| if (t == .string and t.string.len > 0) {
            agent_type = t.string;
        };
    };
    tool_input.put(a, "agent", .{ .string = agent }) catch return null;
    if (agent_type) |t| {
        tool_input.put(a, "agent_type", .{ .string = t }) catch return null;
    } else {
        _ = tool_input.orderedRemove("agent_type");
    }
    const updated = @import("output.zig").json(a, tool_input_value.*);
    return text.concat(a, &.{ "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":", updated, "}}" });
}

test rewrite {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"ls\",\"agent\":\"main\"}}}",
        rewrite(a, "{\"session_id\":\"s\",\"tool_name\":\"mcp__petal__run\",\"tool_input\":{\"command\":\"ls\"},\"agent_type\":\"general-purpose\"}").?,
    );
    try t.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"ls\",\"agent\":\"a1b2\",\"agent_type\":\"Explore\"}}}",
        rewrite(a, "{\"tool_input\":{\"command\":\"ls\",\"agent\":\"forged\"},\"agent_id\":\"a1b2\",\"agent_type\":\"Explore\"}").?,
    );
    try t.expect(rewrite(a, "not json") == null);
    try t.expect(rewrite(a, "{\"tool_input\":\"x\"}") == null);
}
