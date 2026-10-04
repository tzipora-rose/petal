//! petal as an MCP server: JSON-RPC messages, one per line, on standard input and output.
//!
//! Each tools/call runs on a thread of its own, so a long command does not hold up a call from
//! another agent, nor the cancellation of its own call. Every reply also carries the messages
//! waiting in the session's inbox. A line's memory is freed once it is handled; a call's, when its
//! thread ends.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const shell = @import("shell.zig");
const tools = @import("tools.zig");
const inbox = @import("inbox.zig");
const logmod = @import("log.zig");
const session = @import("session.zig");
const Output = @import("output.zig").Output;
const json = @import("output.zig").json;

const Allocator = text.Allocator;
const lasting = text.lasting;

const protocol_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };

const Call = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    id_json: []const u8 = "",
    name: []const u8 = "",
    arguments: ?std.json.ObjectMap = null,
    progress_token: ?[]const u8 = null,
    cancel: win.HANDLE,
};

const Server = struct {
    session: session.Session,
    out: Output,
    lock: win.SRWLOCK = .{},
    calls: std.ArrayList(*Call) = .empty,
};

pub fn serve() noreturn {
    const server = lasting.create(Server) catch text.outOfMemory();
    server.* = .{ .session = session.Session.init(), .out = Output.init() };
    if (std.Thread.spawn(.{ .stack_size = 1 << 20 }, sweep, .{server})) |t| t.detach() else |_| {}

    const stdin = win.GetStdHandle(win.STD_INPUT_HANDLE) orelse finish(server);
    var pending: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (true) {
        var n: win.DWORD = 0;
        if (!win.ReadFile(stdin, &chunk, chunk.len, &n, null).toBool() or n == 0) break;
        pending.appendSlice(lasting, chunk[0..n]) catch text.outOfMemory();
        var start: usize = 0;
        while (std.mem.findScalarPos(u8, pending.items, start, '\n')) |nl| {
            handle(server, pending.items[start..nl]);
            start = nl + 1;
        }
        if (start > 0) {
            const rest = pending.items.len - start;
            std.mem.copyForwards(u8, pending.items[0..rest], pending.items[start..]);
            pending.shrinkRetainingCapacity(rest);
        }
    }
    if (pending.items.len > 0) handle(server, pending.items);
    finish(server);
}

/// Standard input closed: the session is over, and every shell ends with it.
fn finish(server: *Server) noreturn {
    server.session.endAll();
    win.ExitProcess(0);
}

fn sweep(server: *Server) void {
    while (true) {
        win.Sleep(@intCast(server.session.sweepInterval()));
        server.session.sweepIdle();
    }
}

fn handle(server: *Server, raw: []const u8) void {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(lasting);
    defer arena.deinit();
    const a = arena.allocator();
    const line = text.pairSurrogates(a, trimmed);
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
        server.out.failure(a, "null", -32700, "Parse error: a line was not valid JSON");
        return;
    };
    if (value == .array) {
        server.out.failure(a, "null", -32600, "petal does not take JSON-RPC batches");
        return;
    }
    if (value != .object) {
        server.out.failure(a, "null", -32600, "Invalid request");
        return;
    }
    const o = value.object;
    const method_value = o.get("method") orelse return;
    if (method_value != .string) return;
    const method = method_value.string;
    const params = o.get("params");
    const id = o.get("id") orelse {
        notification(server, a, method, params);
        return;
    };
    const id_json = json(a, id);
    if (std.mem.eql(u8, method, "initialize")) {
        server.out.result(a, id_json, initializeResult(a, params));
    } else if (std.mem.eql(u8, method, "ping")) {
        server.out.result(a, id_json, "{}");
    } else if (std.mem.eql(u8, method, "tools/list")) {
        server.out.result(a, id_json, tools.list);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        startCall(server, a, line, id_json, params);
    } else {
        server.out.failure(a, id_json, -32601, text.concat(a, &.{ "Method not found: ", method }));
    }
}

fn initializeResult(a: Allocator, params: ?std.json.Value) []const u8 {
    var version: []const u8 = protocol_versions[0];
    if (params) |p| if (p == .object) if (p.object.get("protocolVersion")) |v| if (v == .string) {
        for (protocol_versions) |known| if (std.mem.eql(u8, known, v.string)) {
            version = known;
        };
    };
    return text.concat(a, &.{
        "{\"protocolVersion\":",                             json(a, version),
        ",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"petal\",\"title\":\"petal\",\"version\":", json(a, @as([]const u8, tools.version)),
        "},\"instructions\":",                               json(a, @as([]const u8, tools.instructions)),
        "}",
    });
}

fn notification(server: *Server, a: Allocator, method: []const u8, params: ?std.json.Value) void {
    if (!std.mem.eql(u8, method, "notifications/cancelled")) return;
    const p = params orelse return;
    if (p != .object) return;
    const request_id = p.object.get("requestId") orelse return;
    const wanted = json(a, request_id);
    win.AcquireSRWLockExclusive(&server.lock);
    defer win.ReleaseSRWLockExclusive(&server.lock);
    for (server.calls.items) |c| if (std.mem.eql(u8, c.id_json, wanted)) {
        _ = win.SetEvent(c.cancel);
    };
}

fn startCall(server: *Server, a: Allocator, line: []const u8, id_json: []const u8, params: ?std.json.Value) void {
    const name = blk: {
        const p = params orelse break :blk null;
        if (p != .object) break :blk null;
        const v = p.object.get("name") orelse break :blk null;
        break :blk if (v == .string) v.string else null;
    } orelse {
        server.out.failure(a, id_json, -32602, "tools/call needs a tool name in params.name");
        return;
    };
    if (!std.mem.eql(u8, name, "run") and !std.mem.eql(u8, name, "shells") and !std.mem.eql(u8, name, "restart")) {
        server.out.failure(a, id_json, -32602, text.concat(a, &.{ "Unknown tool: ", name }));
        return;
    }

    const call = lasting.create(Call) catch text.outOfMemory();
    call.* = .{
        .server = server,
        .arena = std.heap.ArenaAllocator.init(lasting),
        .cancel = win.CreateEventW(null, .TRUE, .FALSE, null) orelse text.outOfMemory(),
    };
    const ca = call.arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, ca, text.dupe(ca, line), .{}) catch text.outOfMemory();
    const p = parsed.object.get("params").?.object;
    call.id_json = text.dupe(ca, id_json);
    call.name = p.get("name").?.string;
    if (p.get("arguments")) |args| if (args == .object) {
        call.arguments = args.object;
    };
    if (p.get("_meta")) |meta| if (meta == .object) if (meta.object.get("progressToken")) |t| {
        call.progress_token = json(ca, t);
    };

    win.AcquireSRWLockExclusive(&server.lock);
    server.calls.append(lasting, call) catch text.outOfMemory();
    win.ReleaseSRWLockExclusive(&server.lock);
    const thread = std.Thread.spawn(.{ .stack_size = 8 << 20 }, runCall, .{call}) catch {
        server.out.failure(a, id_json, -32603, "petal could not start a thread for this call");
        forget(call);
        return;
    };
    thread.detach();
}

/// Removes the call from the list cancellations search, and frees all its memory.
fn forget(call: *Call) void {
    const server = call.server;
    win.AcquireSRWLockExclusive(&server.lock);
    for (server.calls.items, 0..) |c, i| if (c == call) {
        _ = server.calls.swapRemove(i);
        break;
    };
    win.ReleaseSRWLockExclusive(&server.lock);
    win.CloseHandle(call.cancel);
    call.arena.deinit();
    lasting.destroy(call);
}

fn runCall(call: *Call) void {
    defer forget(call);
    const server = call.server;
    const a = call.arena.allocator();
    const reply: ?session.Reply = if (std.mem.eql(u8, call.name, "run"))
        runTool(call, a)
    else if (std.mem.eql(u8, call.name, "shells"))
        .{ .text = session.listing(&server.session, a), .is_error = false }
    else
        restartTool(call, a);
    const r = reply orelse return;
    var reply_text: []const u8 = r.text;
    for (inbox.take(a, server.session.inbox)) |m| {
        reply_text = text.concat(a, &.{ reply_text, "\n\n— A message from the user, sent at ", m.sent, ":\n", m.text });
        var f: logmod.Fields = .{ .a = a };
        f.add("file", m.name);
        f.add("text", m.text);
        server.session.log.record(a, "message delivered", f);
    }
    server.out.result(a, call.id_json, text.concat(a, &.{ "{\"content\":[{\"type\":\"text\",\"text\":", json(a, reply_text), "}],\"isError\":", if (r.is_error) "true" else "false", "}" }));
}

const Arg = union(enum) { absent, value: []const u8, wrong };

fn stringArg(call: *Call, name: []const u8) Arg {
    const args = call.arguments orelse return .absent;
    const v = args.get(name) orelse return .absent;
    return switch (v) {
        .string => |s| .{ .value = s },
        .null => .absent,
        else => .wrong,
    };
}

fn optionalString(call: *Call, a: Allocator, name: []const u8, problem: *?[]const u8) ?[]const u8 {
    return switch (stringArg(call, name)) {
        .absent => null,
        .value => |s| s,
        .wrong => blk: {
            problem.* = text.print(a, "\"{s}\" must be a string", .{name});
            break :blk null;
        },
    };
}

fn shellArg(call: *Call, a: Allocator, problem: *?[]const u8) ?shell.Kind {
    const s = optionalString(call, a, "shell", problem) orelse return null;
    return shell.Kind.parse(s) orelse blk: {
        problem.* = text.print(a, "\"shell\" is \"{s}\"; petal's shells are pwsh (PowerShell 7), powershell (Windows PowerShell 5.1) and bash (Git Bash)", .{s});
        break :blk null;
    };
}

fn invalid(a: Allocator, problem: []const u8) session.Reply {
    return .{ .text = text.concat(a, &.{ "petal did not run this call: ", problem, "." }), .is_error = true };
}

fn runTool(call: *Call, a: Allocator) ?session.Reply {
    var problem: ?[]const u8 = null;
    const command = optionalString(call, a, "command", &problem) orelse return invalid(a, problem orelse "\"command\" is missing");
    if (command.len == 0) return invalid(a, "\"command\" is empty");
    if (std.mem.findScalar(u8, command, 0) != null) return invalid(a, "\"command\" contains a NUL character, which no shell can take");
    var args: session.RunArgs = .{ .command = command };
    if (shellArg(call, a, &problem)) |k| args.kind = k;
    args.stamen = optionalString(call, a, "stamen", &problem);
    args.from = optionalString(call, a, "from", &problem);
    args.agent = optionalString(call, a, "agent", &problem);
    args.agent_type = optionalString(call, a, "agent_type", &problem);
    if (call.arguments) |given| {
        if (given.get("intended")) |v| switch (v) {
            .bool => |b| args.intended = b,
            .null => {},
            else => problem = "\"intended\" must be true or false",
        };
        if (given.get("timeout")) |v| {
            const requested: ?f64 = switch (v) {
                .integer => |i| @floatFromInt(i),
                .float => |x| x,
                .null => null,
                else => blk: {
                    problem = "\"timeout\" must be a number of milliseconds";
                    break :blk null;
                },
            };
            if (requested) |ms| {
                const clamped = std.math.clamp(ms, @as(f64, @floatFromInt(session.min_timeout_ms)), @as(f64, @floatFromInt(session.max_timeout_ms)));
                args.timeout_ms = @intFromFloat(clamped);
                args.timeout_clamped = clamped != ms;
            }
        }
    }
    if (problem) |p| return invalid(a, p);
    return session.run(&call.server.session, a, args, call.cancel, .{ .context = call, .report = report });
}

fn report(context: *anyopaque, a: Allocator, elapsed_s: u64, message: []const u8) void {
    const call: *Call = @ptrCast(@alignCast(context));
    const token = call.progress_token orelse return;
    call.server.out.notify(a, "notifications/progress", text.concat(a, &.{ "{\"progressToken\":", token, ",\"progress\":", text.print(a, "{d}", .{elapsed_s}), ",\"message\":", json(a, message), "}" }));
}

fn restartTool(call: *Call, a: Allocator) ?session.Reply {
    var problem: ?[]const u8 = null;
    var args: session.RestartArgs = .{};
    args.kind = shellArg(call, a, &problem);
    args.stamen = optionalString(call, a, "stamen", &problem);
    args.agent = optionalString(call, a, "agent", &problem);
    if (problem) |p| return invalid(a, p);
    return session.restart(&call.server.session, a, args);
}

test {
    std.testing.refAllDecls(@This());
}
