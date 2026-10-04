//! The session: each agent's stamens and their shells, and what the tools do with them.
//!
//! A stamen is one agent's named set of shells, one of each kind, each started the first time it
//! is used. The main agent's default stamen is "main"; a subagent's is its id; a further stamen of
//! an agent is "<agent>:<name>". A shell runs one command at a time, so a call that finds its
//! shell busy is answered at once. A shell that ends starts again fresh, in the folder it was in.
//!
//! Memory: a call's work lives in the arena `a` it is given. A slot's lasting fields are changed
//! only by the call that holds the slot (busy), under the session's lock, with text.replace; what a
//! call reads from a slot it does not hold is copied into its arena while it holds the lock.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const clock = @import("clock.zig");
const paths = @import("paths.zig");
const shell = @import("shell.zig");
const Env = @import("env.zig").Env;
const bashcheck = @import("bashcheck.zig");
const logmod = @import("log.zig");

const Allocator = text.Allocator;
const lasting = text.lasting;

pub const default_timeout_ms: u64 = 600_000;
pub const max_timeout_ms: u64 = 14_400_000;
pub const min_timeout_ms: u64 = 1_000;
/// The output an agent receives, in UTF-16 code units, as Claude Code counts characters.
pub const output_limit: usize = 30_000;
const head_units: usize = 10_000;
const tail_units: usize = 20_000;
const default_idle_limit_ms: u64 = 30 * 60 * 1000;
const progress_interval_ms: u64 = 10_000;
const output_read_limit: usize = 64 * 1024 * 1024;

pub const Slot = struct {
    kind: shell.Kind,
    process: ?*shell.Process = null,
    busy: bool = false,
    busy_command: ?[]const u8 = null,
    busy_since: u64 = 0,
    busy_since_clock: ?[]const u8 = null,
    /// After the last finished command: the folder as Windows writes it, and as the shell does.
    folder: ?[]const u8 = null,
    location: ?[]const u8 = null,
    /// The environment after the last finished command that changed it: NAME=VALUE entries ending
    /// in NUL for PowerShell, the output of "export -p" for Bash.
    environment: ?[]const u8 = null,
    environment_clock: ?[]const u8 = null,
    commands: u32 = 0,
    starts: u32 = 0,
    /// Why the last process ended, said when the next one starts.
    ended: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const Stamen = struct {
    id: []const u8,
    agent: []const u8,
    agent_type: ?[]const u8,
    from: ?[]const u8,
    slots: [3]Slot,
    last_used: u64,

    pub fn slot(st: *Stamen, kind: shell.Kind) *Slot {
        return &st.slots[@intFromEnum(kind)];
    }
};

pub const Session = struct {
    id: []const u8,
    folder: []const u8,
    outputs: []const u8,
    inbox: []const u8,
    start_folder: []const u8,
    shells: paths.Shells,
    base_env: Env,
    started_clock: []const u8,
    idle_limit_ms: u64,
    log: logmod.Log,
    lock: win.SRWLOCK = .{},
    stamens: std.ArrayList(*Stamen) = .empty,
    seq: u64 = 0,
    noted_missing_agent: bool = false,

    /// Everything here lasts the session.
    pub fn init() Session {
        const a = lasting;
        const id = paths.sessionId(a);
        const data = paths.dataDir(a) orelse paths.join(a, &.{ paths.getEnv(a, "TEMP") orelse ".", "petal" });
        const folder = paths.join(a, &.{ data, "sessions", id });
        const outputs = paths.join(a, &.{ folder, "outputs" });
        const inbox = paths.join(a, &.{ folder, "inbox" });
        _ = paths.makeDirs(a, outputs);
        _ = paths.makeDirs(a, inbox);
        var env = Env.fromProcess(a);
        shell.removeControlVariables(&env);
        removeFolderVariables(&env);
        env.set("POWERSHELL_TELEMETRY_OPTOUT", "1");
        if (paths.claudeExecutable(a)) |claude| env.set("CLAUDE_CODE_EXECPATH", claude);
        const idle_limit: u64 = if (paths.getEnv(a, "PETAL_IDLE_LIMIT_MS")) |v| std.fmt.parseInt(u64, v, 10) catch default_idle_limit_ms else default_idle_limit_ms;
        var s = Session{
            .id = id,
            .folder = folder,
            .outputs = outputs,
            .inbox = inbox,
            .start_folder = paths.currentDirectory(a),
            .shells = paths.findShells(a),
            .base_env = env,
            .started_clock = clock.stamp().clock(a),
            .idle_limit_ms = idle_limit,
            .log = logmod.Log.open(a, paths.join(a, &.{ folder, "log.jsonl" })),
        };
        var arena = std.heap.ArenaAllocator.init(lasting);
        defer arena.deinit();
        var f: logmod.Fields = .{ .a = arena.allocator() };
        f.add("petal", @as([]const u8, @import("tools.zig").version));
        f.add("pid", win.GetCurrentProcessId());
        f.add("folder", s.start_folder);
        f.add("pwsh", s.shells.pwsh);
        f.add("powershell", s.shells.powershell);
        f.add("bash", s.shells.bash);
        s.log.record(arena.allocator(), "session started", f);
        return s;
    }

    fn nextSeq(s: *Session) u64 {
        win.AcquireSRWLockExclusive(&s.lock);
        defer win.ReleaseSRWLockExclusive(&s.lock);
        s.seq += 1;
        return s.seq;
    }

    fn find(s: *Session, id: []const u8) ?*Stamen {
        for (s.stamens.items) |st| if (std.mem.eql(u8, st.id, id)) return st;
        return null;
    }

    fn exe(s: *Session, kind: shell.Kind) ?[]const u8 {
        return switch (kind) {
            .pwsh => s.shells.pwsh,
            .powershell => s.shells.powershell,
            .bash => s.shells.bash,
        };
    }

    /// Ends every shell: the session is over. The log takes no record after this one's.
    pub fn endAll(s: *Session) void {
        var arena = std.heap.ArenaAllocator.init(lasting);
        defer arena.deinit();
        const a = arena.allocator();
        var ending: std.ArrayList(*shell.Process) = .empty;
        win.AcquireSRWLockExclusive(&s.lock);
        for (s.stamens.items) |st| for (&st.slots) |*sl| if (sl.process) |p| {
            ending.append(a, p) catch text.outOfMemory();
            sl.process = null;
        };
        win.ReleaseSRWLockExclusive(&s.lock);
        for (ending.items) |p| p.end();
        s.log.close(a, "session ended", .{ .a = a });
    }

    /// How often the idle sweep runs: often enough to end a stamen soon after its limit.
    pub fn sweepInterval(s: *Session) u64 {
        return std.math.clamp(s.idle_limit_ms / 4, 250, 60_000);
    }

    /// Ends the shells of stamens other than "main" that no command has used for the idle limit.
    pub fn sweepIdle(s: *Session) void {
        var arena = std.heap.ArenaAllocator.init(lasting);
        defer arena.deinit();
        const a = arena.allocator();
        var ended: std.ArrayList(*shell.Process) = .empty;
        win.AcquireSRWLockExclusive(&s.lock);
        const now = clock.ms();
        const why = text.print(a, "this stamen's shells ended after {d} minutes unused", .{s.idle_limit_ms / 60_000});
        for (s.stamens.items) |st| {
            if (std.mem.eql(u8, st.id, "main")) continue;
            if (now -| st.last_used < s.idle_limit_ms) continue;
            for (&st.slots) |*sl| {
                if (sl.busy) continue;
                const p = sl.process orelse continue;
                sl.process = null;
                text.replace(&sl.ended, why);
                ended.append(a, p) catch text.outOfMemory();
                var f: logmod.Fields = .{ .a = a };
                f.add("stamen", st.id);
                f.add("shell", sl.kind.label());
                f.add("reason", @as([]const u8, "idle"));
                s.log.record(a, "shell ended", f);
            }
        }
        win.ReleaseSRWLockExclusive(&s.lock);
        for (ended.items) |p| p.end();
    }
};

pub const RunArgs = struct {
    command: []const u8,
    kind: shell.Kind = .pwsh,
    stamen: ?[]const u8 = null,
    from: ?[]const u8 = null,
    timeout_ms: u64 = default_timeout_ms,
    timeout_clamped: bool = false,
    intended: bool = false,
    agent: ?[]const u8 = null,
    agent_type: ?[]const u8 = null,
};

pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, a: Allocator, elapsed_s: u64, message: []const u8) void,
};

pub const Reply = struct {
    text: []const u8,
    is_error: bool,
};

const Notes = struct {
    a: Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn add(n: *Notes, line: []const u8) void {
        n.lines.append(n.a, line) catch text.outOfMemory();
    }
};

/// A stamen name an agent chooses: letters, digits, dot, dash, underscore; ":" separates an
/// agent from the names of its stamens, so it may not appear in one.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    return true;
}

fn agentOf(s: *Session, agent: ?[]const u8, notes: *Notes) []const u8 {
    if (agent) |name| if (name.len > 0) return name;
    win.AcquireSRWLockExclusive(&s.lock);
    const first = !s.noted_missing_agent;
    s.noted_missing_agent = true;
    win.ReleaseSRWLockExclusive(&s.lock);
    if (first) notes.add("no agent identity came with this call (petal's hook did not run), so petal used the main agent's shells; it says this once per session");
    return "main";
}

fn stamenId(a: Allocator, agent: []const u8, name: ?[]const u8) []const u8 {
    const n = name orelse return agent;
    if (n.len == 0) return agent;
    return text.concat(a, &.{ agent, ":", n });
}

/// What a new shell copies from another stamen's shell of its kind, copied into the call's arena.
const CopySource = struct {
    stamen: []const u8,
    folder: ?[]const u8,
    environment: ?[]const u8,
    environment_clock: ?[]const u8,
};

fn copyOf(a: Allocator, s: ?[]const u8) ?[]const u8 {
    return if (s) |x| text.dupe(a, x) else null;
}

/// Runs a command; null when the call was cancelled, which MCP answers with nothing.
pub fn run(s: *Session, a: Allocator, args: RunArgs, cancel: win.HANDLE, progress: Progress) ?Reply {
    var notes: Notes = .{ .a = a };
    const agent = agentOf(s, args.agent, &notes);
    if (args.stamen) |n| if (n.len > 0 and !validName(n)) {
        return .{ .text = text.print(a, "petal did not run this command: \"{s}\" cannot name a stamen. A stamen's name uses letters, digits, dot, dash and underscore, at most 64 of them.", .{n}), .is_error = true };
    };
    const id = stamenId(a, agent, args.stamen);

    win.AcquireSRWLockExclusive(&s.lock);
    if (args.from) |f| if (s.find(f) == null) {
        win.ReleaseSRWLockExclusive(&s.lock);
        return .{ .text = text.print(a, "petal did not run this command: there is no stamen \"{s}\" to start from. The shells tool lists the session's stamens.", .{f}), .is_error = true };
    };
    const st = s.find(id) orelse blk: {
        const created = lasting.create(Stamen) catch text.outOfMemory();
        created.* = .{
            .id = text.dupe(lasting, id),
            .agent = text.dupe(lasting, agent),
            .agent_type = if (args.agent_type) |t| text.dupe(lasting, t) else null,
            .from = if (args.from) |f| text.dupe(lasting, f) else null,
            .slots = .{ .{ .kind = .pwsh }, .{ .kind = .powershell }, .{ .kind = .bash } },
            .last_used = clock.ms(),
        };
        s.stamens.append(lasting, created) catch text.outOfMemory();
        break :blk created;
    };
    const sl = st.slot(args.kind);
    if (sl.busy) {
        const reply = busyReply(a, st, sl);
        win.ReleaseSRWLockExclusive(&s.lock);
        logRun(s, a, st, args, "busy", null, 0, null, 0);
        return reply;
    }
    sl.busy = true;
    text.replace(&sl.busy_command, args.command);
    sl.busy_since = clock.ms();
    text.replace(&sl.busy_since_clock, clock.stamp().clock(a));
    st.last_used = clock.ms();
    var copy: ?CopySource = null;
    if (sl.starts == 0) if (args.from orelse st.from) |source_id| {
        if (s.find(source_id)) |source| {
            const src = source.slot(args.kind);
            copy = .{ .stamen = text.dupe(a, source.id), .folder = copyOf(a, src.folder), .environment = copyOf(a, src.environment), .environment_clock = copyOf(a, src.environment_clock) };
        }
    };
    const already_running = sl.process != null;
    win.ReleaseSRWLockExclusive(&s.lock);

    defer {
        win.AcquireSRWLockExclusive(&s.lock);
        sl.busy = false;
        st.last_used = clock.ms();
        win.ReleaseSRWLockExclusive(&s.lock);
    }

    if (args.from != null and already_running) {
        notes.add(text.print(a, "from was not used: this {s} shell was already running, and from applies when a shell starts", .{args.kind.label()}));
    }
    if (args.timeout_clamped) notes.add(text.print(a, "the timeout was set to {d} ms, the most or least petal allows", .{args.timeout_ms}));

    const p = switch (ensureStarted(s, a, st, sl, copy, &notes)) {
        .process => |p| p,
        .failure => |failure| return withNotes(a, failure, &notes),
    };
    defer p.release();

    if (!args.intended and args.kind == .bash) {
        if (bashFindings(s, a, st, sl, p, args.command)) |reply| {
            logRun(s, a, st, args, "not run: check", null, 0, null, 0);
            return withNotes(a, reply, &notes);
        }
    }

    const seq = s.nextSeq();
    const out_path = paths.join(a, &.{ s.outputs, text.print(a, "{d}.txt", .{seq}) });
    const sent = switch (args.kind) {
        .bash => p.send(shell.bashLine(a, "run", seq, text.concat(a, &.{ out_path, "\n", args.command }))),
        .pwsh, .powershell => p.send(shell.powershellRequest(a, "run", seq, std.json.Stringify.valueAlloc(a, .{ .command = text.validUtf8(a, args.command), .out = out_path, .check = !args.intended }, .{}) catch text.outOfMemory())),
    };
    // The timeout counts from here. A Stop gate that attributes file writes to petal calls may
    // count a call as running only until its start, plus its timeout, plus a fixed margin (2
    // minutes in the gate this was checked against), so the waits above, before the send, must
    // stay well inside that margin: now at most about 95 s.
    const t0 = clock.ms();
    const deadline = t0 + args.timeout_ms;
    var outcome: shell.Process.Wait = if (sent) .tick else .ended;
    while (outcome == .tick) {
        outcome = p.wait(a, seq, deadline, cancel, progress_interval_ms);
        if (outcome == .tick) {
            const elapsed = (clock.ms() - t0) / 1000;
            progress.report(progress.context, a, elapsed, text.print(a, "{s} in stamen {s}: running for {d} s", .{ args.kind.label(), st.id, elapsed }));
        }
    }
    const seconds = @as(f64, @floatFromInt(clock.ms() - t0)) / 1000.0;
    // Read before the kill below: Git's bin\bash.exe outlives the Bash it runs by a moment to pass
    // its exit code on, and ending it first would replace that code.
    const shell_code: ?u32 = if (outcome == .ended) p.exitCodeWithin(2000) else null;
    switch (outcome) {
        .frame => |f| strayNote(a, &notes, if (std.mem.eql(u8, f.op, "done")) p.takeStray(a, seq, 2000) else p.takeStray(a, null, 0)),
        .timed_out, .ended => {
            p.kill();
            strayNote(a, &notes, p.takeStray(a, std.math.maxInt(u64), 2000));
        },
        .cancelled, .tick => {},
    }

    switch (outcome) {
        .tick => unreachable,
        .cancelled => {
            endShell(s, a, st, sl, "the call before this one was cancelled while its command ran, and petal ended the shell and everything it started");
            logRun(s, a, st, args, "cancelled", null, seconds, out_path, 0);
            return null;
        },
        .timed_out => {
            endShell(s, a, st, sl, text.print(a, "the command before this one ran past its timeout of {d} s, and petal ended the shell and everything it started", .{args.timeout_ms / 1000}));
            const out = readOutput(a, out_path);
            notes.add(text.print(a, "the command did not finish within {d} s, so petal ended it, its shell and everything it started; the next command in this shell starts a fresh one in the same folder, without its variables and functions", .{args.timeout_ms / 1000}));
            logRun(s, a, st, args, "timed out", null, seconds, out_path, out.total_units);
            return withNotes(a, .{ .text = text.concat(a, &.{ body(out.text), statusLine(a, st, sl, null, seconds) }), .is_error = true }, &notes);
        },
        .ended => {
            const code = shell_code;
            endShell(s, a, st, sl, if (code) |c| text.print(a, "the shell ended (exit code {d}) while running the command before this one", .{c}) else "the shell ended while running the command before this one");
            const out = readOutput(a, out_path);
            notes.add(if (code) |c| text.print(a, "the shell itself ended (exit code {d}) while running this command; the next command starts a fresh one in the same folder, without its variables and functions", .{c}) else "the shell itself ended while running this command; the next command starts a fresh one in the same folder");
            const exit_code: ?i64 = if (code) |c| @as(i64, c) else null;
            logRun(s, a, st, args, "shell ended", exit_code, seconds, out_path, out.total_units);
            return withNotes(a, .{ .text = text.concat(a, &.{ body(out.text), statusLine(a, st, sl, exit_code, seconds) }), .is_error = false }, &notes);
        },
        .frame => |f| {
            if (std.mem.eql(u8, f.op, "checked")) {
                logRun(s, a, st, args, "not run: check", null, seconds, null, 0);
                return withNotes(a, powershellFindingsReply(a, st, sl, f.json), &notes);
            }
            if (std.mem.eql(u8, f.op, "failed")) {
                logRun(s, a, st, args, "failed", null, seconds, null, 0);
                return withNotes(a, .{ .text = text.print(a, "petal's loop in the shell could not run this command: {s}", .{jsonField(a, f.json, "message") orelse "no reason given"}), .is_error = true }, &notes);
            }
            const exit_code = recordDone(s, a, sl, f);
            const out = readOutput(a, out_path);
            if (out.truncated) notes.add(text.print(a, "the output was {d} characters in {d} lines; the reply shows the first and last of it. All of it: {s}", .{ out.total_units, out.total_lines, out_path }));
            logRun(s, a, st, args, "ran", exit_code, seconds, out_path, out.total_units);
            return withNotes(a, .{ .text = text.concat(a, &.{ body(out.text), statusLine(a, st, sl, exit_code, seconds) }), .is_error = false }, &notes);
        },
    }
}

fn strayNote(a: Allocator, notes: *Notes, stray: shell.Process.Stray) void {
    if (stray.bytes.len == 0 and stray.dropped == 0) return;
    notes.add(text.concat(a, &.{ "written straight to the shell's own output, bypassing the command's output, since the previous command in this shell ended:\n", std.mem.trimEnd(u8, text.cleanOutput(a, stray.bytes), "\n"), if (stray.dropped > 0) text.print(a, "\n[{d} more bytes not kept]", .{stray.dropped}) else "" }));
}

const Started = union(enum) {
    /// The slot's running shell, held for the caller, who lets go of it with release().
    process: *shell.Process,
    failure: Reply,
};

/// The slot's shell, started when it is not running. The caller holds the slot.
fn ensureStarted(s: *Session, a: Allocator, st: *Stamen, sl: *Slot, copy: ?CopySource, notes: *Notes) Started {
    win.AcquireSRWLockExclusive(&s.lock);
    const current = sl.process;
    if (current) |p| p.retain();
    win.ReleaseSRWLockExclusive(&s.lock);
    if (current) |p| {
        if (p.isRunning()) return .{ .process = p };
        const code = p.exitCode();
        win.AcquireSRWLockExclusive(&s.lock);
        if (sl.process == p) sl.process = null;
        text.replace(&sl.ended, if (code) |c| text.print(a, "the shell had ended on its own (exit code {d})", .{c}) else "the shell had ended on its own");
        win.ReleaseSRWLockExclusive(&s.lock);
        p.end();
        p.release();
    }
    const exe = s.exe(sl.kind) orelse return .{ .failure = .{ .text = text.print(a, "petal could not start {s}: {s} was not found on this computer.", .{ sl.kind.label(), sl.kind.product() }), .is_error = true } };

    var folder = s.start_folder;
    var folder_note: ?[]const u8 = null;
    if (copy) |c| if (c.folder) |f| {
        if (paths.isDir(a, windowsForm(a, f))) folder = windowsForm(a, f) else folder_note = text.print(a, "the folder of stamen {s}, {s}, no longer exists", .{ c.stamen, f });
    };
    if (copy == null or copy.?.folder == null) if (sl.folder) |f| {
        if (paths.isDir(a, windowsForm(a, f))) folder = windowsForm(a, f) else folder_note = text.print(a, "the folder it was in, {s}, no longer exists", .{f});
    };

    var env = s.base_env.clone(a);
    var copied_env = false;
    if (copy) |c| if (c.environment) |e| if (sl.kind != .bash) {
        env = Env.fromSnapshot(a, e);
        shell.removeControlVariables(&env);
        removeFolderVariables(&env);
        if (s.base_env.get("CLAUDE_CODE_EXECPATH")) |v| env.setWide("CLAUDE_CODE_EXECPATH", v);
        env.set("POWERSHELL_TELEMETRY_OPTOUT", "1");
        copied_env = true;
    };

    var diagnostic: []const u8 = "";
    const p = shell.start(a, sl.kind, exe, folder, &env, &diagnostic) catch {
        var f: logmod.Fields = .{ .a = a };
        f.add("stamen", st.id);
        f.add("shell", sl.kind.label());
        f.add("problem", diagnostic);
        s.log.record(a, "shell failed to start", f);
        return .{ .failure = .{ .text = text.print(a, "petal could not start {s} ({s}): {s}", .{ sl.kind.label(), exe, diagnostic }), .is_error = true } };
    };

    if (copy) |c| if (c.environment) |e| if (sl.kind == .bash) {
        const seq = s.nextSeq();
        if (p.send(shell.bashLine(a, "restore", seq, e))) {
            if (p.wait(a, seq, clock.ms() + 10_000, null, 10_000) == .frame) copied_env = true;
        }
    };

    const ended = copyOf(a, sl.ended);
    win.AcquireSRWLockExclusive(&s.lock);
    sl.process = p;
    p.retain();
    sl.starts += 1;
    text.replace(&sl.version, p.version);
    text.replace(&sl.ended, null);
    if (sl.folder == null) text.replace(&sl.folder, folder);
    win.ReleaseSRWLockExclusive(&s.lock);

    var note = text.print(a, "started a new {s} {s} shell in {s}", .{ sl.kind.product(), p.version, folder });
    if (ended) |why| note = text.concat(a, &.{ note, "; ", why, ", so its variables and functions are gone" });
    if (folder_note) |fn_| note = text.concat(a, &.{ note, "; ", fn_ });
    if (copy) |c| {
        if (c.folder != null or copied_env) {
            note = text.concat(a, &.{ note, text.print(a, "; it started from stamen {s}'s {s} shell: its folder{s}, as of its last finished command{s}", .{ c.stamen, sl.kind.label(), if (copied_env) " and environment variables" else "", if (c.environment_clock) |t| text.concat(a, &.{ " at ", t }) else "" }) });
        } else {
            note = text.concat(a, &.{ note, text.print(a, "; stamen {s} had not run a command in {s} yet, so nothing was copied from it", .{ c.stamen, sl.kind.label() }) });
        }
    }
    notes.add(note);
    var f: logmod.Fields = .{ .a = a };
    f.add("stamen", st.id);
    f.add("shell", sl.kind.label());
    f.add("version", p.version);
    f.add("pid", p.pid);
    f.add("folder", folder);
    f.add("from", if (copy) |c| c.stamen else null);
    s.log.record(a, "shell started", f);
    return .{ .process = p };
}

/// Bash keeps an inherited PWD that names the folder it starts in, in whatever form it is written,
/// so a shell gets none and works its folder out itself.
fn removeFolderVariables(env: *Env) void {
    env.remove("PWD");
    env.remove("OLDPWD");
}

fn windowsForm(a: Allocator, path: []const u8) []const u8 {
    if (std.mem.findScalar(u8, path, '/') == null) return path;
    const out = text.dupe(a, path);
    for (out) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    return out;
}

/// Ends the slot's shell, which the caller holds, and records why for the next start.
fn endShell(s: *Session, a: Allocator, st: *Stamen, sl: *Slot, why: []const u8) void {
    win.AcquireSRWLockExclusive(&s.lock);
    const p = sl.process;
    sl.process = null;
    text.replace(&sl.ended, why);
    win.ReleaseSRWLockExclusive(&s.lock);
    if (p) |x| x.end();
    var f: logmod.Fields = .{ .a = a };
    f.add("stamen", st.id);
    f.add("shell", sl.kind.label());
    f.add("reason", why);
    s.log.record(a, "shell ended", f);
}

/// Takes in the shell's answer to a finished command: its folder and environment. The exit code.
fn recordDone(s: *Session, a: Allocator, sl: *Slot, f: shell.Frame) ?i64 {
    var exit_code: ?i64 = null;
    var folder: ?[]const u8 = null;
    var location: ?[]const u8 = null;
    var environment: ?[]const u8 = null;
    switch (sl.kind) {
        .bash => {
            exit_code = f.status;
            folder = f.fields[0];
            location = f.fields[1];
            if (f.fields[2].len > 0) environment = f.fields[2];
        },
        .pwsh, .powershell => {
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, f.json, .{}) catch return null;
            if (parsed != .object) return null;
            const o = parsed.object;
            if (o.get("exit")) |v| exit_code = switch (v) {
                .integer => |i| i,
                .float => |x| @intFromFloat(x),
                else => null,
            };
            folder = jsonString(o.get("folder"));
            location = jsonString(o.get("location"));
            environment = jsonString(o.get("environment"));
            if (folder != null and folder.?.len == 0) folder = null;
        },
    }
    const now = clock.stamp().clock(a);
    win.AcquireSRWLockExclusive(&s.lock);
    defer win.ReleaseSRWLockExclusive(&s.lock);
    sl.commands += 1;
    if (folder) |x| text.replace(&sl.folder, x);
    if (location) |x| text.replace(&sl.location, x);
    if (environment) |x| {
        text.replace(&sl.environment, x);
        text.replace(&sl.environment_clock, now);
    } else if (sl.environment_clock == null) {
        text.replace(&sl.environment_clock, now);
    }
    return exit_code;
}

fn jsonString(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonField(a: Allocator, json: []const u8, name: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return null;
    if (parsed != .object) return null;
    return jsonString(parsed.object.get(name));
}

const Output = struct {
    text: []const u8,
    truncated: bool,
    total_units: usize,
    total_lines: usize,
};

/// The command's output as the agent receives it: valid UTF-8 with "\n" line endings, and when it
/// is longer than 30,000 characters, its first 10,000 and its last 20,000, cut at lines.
fn readOutput(a: Allocator, path: []const u8) Output {
    const raw = paths.readFile(a, path, output_read_limit) orelse return .{ .text = "", .truncated = false, .total_units = 0, .total_lines = 0 };
    const bytes = if (std.mem.startsWith(u8, raw, "\xef\xbb\xbf")) raw[3..] else raw;
    const all = text.cleanOutput(a, bytes);
    const units = text.utf16Length(all);
    const lines = text.countLines(all);
    if (units <= output_limit) return .{ .text = all, .truncated = false, .total_units = units, .total_lines = lines };

    var head_end = text.offsetOfUnits(all, head_units);
    if (std.mem.findScalarLast(u8, all[0..head_end], '\n')) |nl| {
        if (text.utf16Length(all[0..nl]) >= head_units / 2) head_end = nl + 1;
    }
    var tail_start = text.offsetOfUnits(all, units - tail_units);
    while (tail_start < all.len and (all[tail_start] & 0xC0) == 0x80) tail_start += 1;
    if (std.mem.findScalarPos(u8, all, tail_start, '\n')) |nl| {
        if (text.utf16Length(all[nl + 1 ..]) >= tail_units / 2) tail_start = nl + 1;
    }
    if (tail_start < head_end) tail_start = head_end;
    const left_out = all[head_end..tail_start];
    const marker = text.print(a, "\n[… {d} characters in {d} lines not shown …]\n", .{ text.utf16Length(left_out), text.countLines(left_out) });
    return .{ .text = text.concat(a, &.{ all[0..head_end], marker, all[tail_start..] }), .truncated = true, .total_units = units, .total_lines = lines };
}

fn body(output: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, output, "\n");
    return if (trimmed.len == 0) "(no output)" else trimmed;
}

fn duration(a: Allocator, seconds: f64) []const u8 {
    if (seconds < 10) return text.print(a, "{d:.2} s", .{seconds});
    if (seconds < 120) return text.print(a, "{d:.1} s", .{seconds});
    const total: u64 = @intFromFloat(seconds);
    return text.print(a, "{d} min {d:0>2} s", .{ total / 60, total % 60 });
}

/// The slot's folder in the shell's own form. The caller holds the slot or the session's lock.
fn where(sl: *Slot) []const u8 {
    if (sl.kind == .bash) return sl.location orelse sl.folder orelse "?";
    return sl.folder orelse sl.location orelse "?";
}

fn statusLine(a: Allocator, st: *Stamen, sl: *Slot, exit_code: ?i64, seconds: f64) []const u8 {
    const code = if (exit_code) |c| text.print(a, "exit code {d}", .{c}) else "no exit code";
    return text.print(a, "\n— {s}, {s}, {s} in stamen {s}, folder {s}", .{ code, duration(a, seconds), sl.kind.label(), st.id, where(sl) });
}

fn withNotes(a: Allocator, reply: Reply, notes: *Notes) Reply {
    if (notes.lines.items.len == 0) return reply;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, reply.text) catch text.outOfMemory();
    for (notes.lines.items) |line| {
        out.appendSlice(a, "\n— ") catch text.outOfMemory();
        out.appendSlice(a, line) catch text.outOfMemory();
    }
    return .{ .text = out.items, .is_error = reply.is_error };
}

/// Called with the session's lock held, since another call holds the slot.
fn busyReply(a: Allocator, st: *Stamen, sl: *Slot) Reply {
    const seconds = (clock.ms() -| sl.busy_since) / 1000;
    return .{
        .text = text.print(a, "petal did not run this command: the {s} shell of stamen {s} is busy with `{s}`, running since {s} ({d} s). To run this now, use another stamen of yours: add \"stamen\" with a new name (each stamen has its own shells), and \"from\": \"{s}\" to start it in this stamen's folder with its environment variables.", .{ sl.kind.label(), st.id, text.firstLine(a, sl.busy_command orelse "", 200), sl.busy_since_clock orelse "?", seconds, st.id }),
        .is_error = true,
    };
}

const Found = struct {
    a: Allocator,
    lines: std.ArrayList([]const u8) = .empty,

    fn add(f: *Found, line: []const u8) void {
        f.lines.append(f.a, line) catch text.outOfMemory();
    }

    fn reply(f: *Found, st: *Stamen, sl: *Slot) Reply {
        var out: std.ArrayList(u8) = .empty;
        const n = f.lines.items.len;
        out.print(f.a, "petal did not run this command: its check found {d} thing{s}.\n", .{ n, if (n == 1) "" else "s" }) catch text.outOfMemory();
        for (f.lines.items, 1..) |line, i| out.print(f.a, "{d}. {s}\n", .{ i, line }) catch text.outOfMemory();
        out.print(f.a, "Fix the command, or send it again with \"intended\": true to run it exactly as written.\n— {s} in stamen {s}, folder {s}", .{ sl.kind.label(), st.id, where(sl) }) catch text.outOfMemory();
        return .{ .text = out.items, .is_error = true };
    }
};

fn powershellFindingsReply(a: Allocator, st: *Stamen, sl: *Slot, json: []const u8) Reply {
    var found: Found = .{ .a = a };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch {
        found.add("petal's check gave an answer petal could not read");
        return found.reply(st, sl);
    };
    if (parsed != .object) {
        found.add("petal's check gave an answer petal could not read");
        return found.reply(st, sl);
    }
    const o = parsed.object;
    if (o.get("errors")) |errors| if (errors == .array) for (errors.array.items) |e| {
        if (e != .object) continue;
        found.add(text.print(a, "It does not parse: line {d}, column {d}: {s}", .{ jsonInt(e.object.get("line")), jsonInt(e.object.get("column")), jsonString(e.object.get("message")) orelse "" }));
    };
    if (o.get("findings")) |findings| if (findings == .array) for (findings.array.items) |e| {
        if (e != .object) continue;
        found.add(text.print(a, "Line {d}, `{s}`: {s}", .{ jsonInt(e.object.get("line")), text.firstLine(a, jsonString(e.object.get("text")) orelse "", 160), jsonString(e.object.get("message")) orelse "" }));
    };
    if (found.lines.items.len == 0) found.add("petal's check stopped the command without saying why");
    return found.reply(st, sl);
}

fn jsonInt(v: ?std.json.Value) i64 {
    const value = v orelse return 0;
    return switch (value) {
        .integer => |i| i,
        .float => |x| @intFromFloat(x),
        else => 0,
    };
}

/// Bash's syntax, by Bash itself, and the two deletion rules; null when there is nothing to say.
fn bashFindings(s: *Session, a: Allocator, st: *Stamen, sl: *Slot, p: *shell.Process, command: []const u8) ?Reply {
    var found: Found = .{ .a = a };
    if (syntaxProblem(s, a, command)) |problem| {
        found.add(text.concat(a, &.{ "It does not parse: ", problem }));
        return found.reply(st, sl);
    }
    const reading = bashcheck.read(a, command);
    const dels = bashcheck.deletions(a, reading);
    if (dels.list.len == 0) return null;
    const changes_folder = bashcheck.changesFolder(a, reading);

    var wanted: std.ArrayList([]const u8) = .empty;
    for (dels.list) |d| for (d.targets) |t| for (bashcheck.variables(a, t)) |v| {
        if (!contains(dels.assigned, v) and !contains(wanted.items, v)) wanted.append(a, v) catch text.outOfMemory();
    };
    var values: []?[]const u8 = &.{};
    if (wanted.items.len > 0) {
        const seq = s.nextSeq();
        if (p.send(shell.bashLine(a, "resolve", seq, std.mem.join(a, " ", wanted.items) catch text.outOfMemory()))) {
            switch (p.wait(a, seq, clock.ms() + 10_000, null, 10_000)) {
                .frame => |f| values = f.values,
                else => {},
            }
        }
    }
    const cwd = sl.location orelse "";
    const folder_changes = " This command also changes the folder, so by the time it deletes, the target may resolve elsewhere.";
    for (dels.list) |d| {
        for (d.targets) |t| {
            const vars = bashcheck.variables(a, t);
            const shown = text.firstLine(a, d.command.raw, 160);
            if (vars.len > 0 or bashcheck.hasOther(t)) {
                const names = namesIn(a, t);
                var set_here: std.ArrayList([]const u8) = .empty;
                for (vars) |v| {
                    const n = text.concat(a, &.{ "$", v });
                    if (contains(dels.assigned, v) and !contains(set_here.items, n)) set_here.append(a, n) catch text.outOfMemory();
                }
                if (set_here.items.len > 0) {
                    found.add(text.print(a, "Line {d}, `{s}`: This deletion's target is built from {s}, and {s} gets its value only as this command runs, so petal cannot show what the target will be.", .{ d.command.line, shown, names, std.mem.join(a, ", ", set_here.items) catch text.outOfMemory() }));
                    continue;
                }
                if (bashcheck.hasOther(t) or values.len != wanted.items.len) {
                    found.add(text.print(a, "Line {d}, `{s}`: This deletion's target is built from {s}, and working out what it resolves to would mean running code, so petal cannot show it.", .{ d.command.line, shown, names }));
                    continue;
                }
                var target: std.ArrayList(u8) = .empty;
                var empty: std.ArrayList([]const u8) = .empty;
                for (t.parts) |part| switch (part) {
                    .literal => |l| target.appendSlice(a, l) catch text.outOfMemory(),
                    .variable => |v| {
                        const value = valueOf(wanted.items, values, v);
                        if (value == null or value.?.len == 0) {
                            const n = text.concat(a, &.{ "$", v });
                            if (!contains(empty.items, n)) empty.append(a, n) catch text.outOfMemory();
                        } else target.appendSlice(a, value.?) catch text.outOfMemory();
                    },
                    .other => {},
                };
                const resolved = if (bashcheck.isAbsolute(target.items) or cwd.len == 0) target.items else bashcheck.joinPath(a, cwd, target.items);
                const empty_note: []const u8 = if (empty.items.len == 0) "" else text.concat(a, &.{ " ", std.mem.join(a, ", ", empty.items) catch text.outOfMemory(), if (empty.items.len == 1) " is empty or unset." else " are empty or unset." });
                const folder_note: []const u8 = if (changes_folder and !bashcheck.isAbsolute(target.items)) folder_changes else "";
                found.add(text.print(a, "Line {d}, `{s}`: This deletion's target is built from {s}, and resolves now to: {s}.{s}{s}", .{ d.command.line, shown, names, resolved, empty_note, folder_note }));
                continue;
            }
            const literal = bashcheck.literalText(a, t) orelse continue;
            if (bashcheck.isAbsolute(literal)) continue;
            const resolved = if (cwd.len > 0) bashcheck.joinPath(a, cwd, literal) else literal;
            found.add(text.print(a, "Line {d}, `{s}`: This deletion's target '{s}' is a relative path, so it depends on the shell's folder; from the shell's folder now it resolves to: {s}.{s}", .{ d.command.line, shown, literal, resolved, if (changes_folder) folder_changes else "" }));
        }
    }
    if (found.lines.items.len == 0) return null;
    return found.reply(st, sl);
}

fn namesIn(a: Allocator, t: bashcheck.Word) []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (t.parts) |part| switch (part) {
        .variable => |v| {
            const n = text.concat(a, &.{ "$", v });
            if (!contains(names.items, n)) names.append(a, n) catch text.outOfMemory();
        },
        .other => |o| if (!contains(names.items, o)) names.append(a, o) catch text.outOfMemory(),
        .literal => {},
    };
    return std.mem.join(a, ", ", names.items) catch text.outOfMemory();
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

fn valueOf(names: []const []const u8, values: []?[]const u8, name: []const u8) ?[]const u8 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return if (i < values.len) values[i] else null;
    return null;
}

/// What Bash says is wrong with the command's syntax, from "bash -n", or null.
fn syntaxProblem(s: *Session, a: Allocator, command: []const u8) ?[]const u8 {
    const exe = s.shells.bash_syntax orelse return null;
    var stdin_r: win.HANDLE = undefined;
    var stdin_w: win.HANDLE = undefined;
    var out_r: win.HANDLE = undefined;
    var out_w: win.HANDLE = undefined;
    if (!win.CreatePipe(&stdin_r, &stdin_w, null, 65536).toBool()) return null;
    if (!win.CreatePipe(&out_r, &out_w, null, 65536).toBool()) {
        win.CloseHandle(stdin_r);
        win.CloseHandle(stdin_w);
        return null;
    }
    _ = win.SetHandleInformation(stdin_r, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
    _ = win.SetHandleInformation(out_w, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
    var si = std.mem.zeroes(win.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
    si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = stdin_r;
    si.StartupInfo.hStdOutput = out_w;
    si.StartupInfo.hStdError = out_w;
    var inherit = [_]win.HANDLE{ stdin_r, out_w };
    var attr_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr = a.alignedAlloc(u8, .of(usize), attr_size) catch text.outOfMemory();
    var ok = win.InitializeProcThreadAttributeList(attr.ptr, 1, 0, &attr_size).toBool() and
        win.UpdateProcThreadAttribute(attr.ptr, 0, win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit, inherit.len * @sizeOf(win.HANDLE), null, null).toBool();
    si.lpAttributeList = attr.ptr;
    var info: win.PROCESS_INFORMATION = undefined;
    var env = s.base_env.clone(a);
    const block = env.block();
    if (ok) {
        ok = win.CreateProcessW(text.wide(a, exe).ptr, text.wide(a, text.print(a, "\"{s}\" --noprofile --norc -n", .{exe})).ptr, null, null, .TRUE, .{ .create_no_window = true, .create_unicode_environment = true, .extended_startupinfo_present = true }, block.ptr, null, &si.StartupInfo, &info).toBool();
        win.DeleteProcThreadAttributeList(attr.ptr);
    }
    win.CloseHandle(stdin_r);
    win.CloseHandle(out_w);
    if (!ok) {
        win.CloseHandle(stdin_w);
        win.CloseHandle(out_r);
        return null;
    }
    win.CloseHandle(info.hThread);
    _ = paths.writeAll(stdin_w, command);
    win.CloseHandle(stdin_w);
    const said = paths.readAll(a, out_r, 64 * 1024);
    win.CloseHandle(out_r);
    if (win.WaitForSingleObject(info.hProcess, 10_000) != win.WAIT_OBJECT_0) _ = win.TerminateProcess(info.hProcess, 1);
    var code: win.DWORD = 0;
    _ = win.GetExitCodeProcess(info.hProcess, &code);
    win.CloseHandle(info.hProcess);
    if (code == 0) return null;
    const message = std.mem.trim(u8, text.cleanOutput(a, said), " \n");
    return if (message.len > 0) message else "bash -n reported a syntax error without saying where";
}

fn logRun(s: *Session, a: Allocator, st: *Stamen, args: RunArgs, result: []const u8, exit_code: ?i64, seconds: f64, output: ?[]const u8, output_chars: usize) void {
    var f: logmod.Fields = .{ .a = a };
    f.add("agent", st.agent);
    f.add("agent_type", st.agent_type);
    f.add("stamen", st.id);
    f.add("shell", args.kind.label());
    f.add("command", args.command);
    f.add("intended", args.intended);
    f.add("result", result);
    f.add("exit", exit_code);
    f.add("seconds", seconds);
    f.add("output", output);
    f.add("output_chars", output_chars);
    s.log.record(a, "run", f);
}

/// The text of the shells tool.
pub fn listing(s: *Session, a: Allocator) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    win.AcquireSRWLockExclusive(&s.lock);
    defer win.ReleaseSRWLockExclusive(&s.lock);
    out.print(a, "petal {s}, session {s}, started {s}. The log and every command's full output: {s}\n", .{ @import("tools.zig").version, s.id, s.started_clock, s.folder }) catch text.outOfMemory();
    if (s.stamens.items.len == 0) {
        out.appendSlice(a, "No stamen has run a command yet.") catch text.outOfMemory();
        return out.items;
    }
    const now = clock.ms();
    for (s.stamens.items) |st| {
        const who = if (std.mem.eql(u8, st.agent, "main")) "the main agent" else text.concat(a, &.{ "subagent ", st.agent, if (st.agent_type) |t| text.concat(a, &.{ " (", t, ")" }) else "" });
        out.print(a, "\nstamen {s}, of {s}{s}\n", .{ st.id, who, if (st.from) |f| text.concat(a, &.{ ", started from ", f }) else "" }) catch text.outOfMemory();
        for (&st.slots) |*sl| {
            const state = if (sl.busy)
                text.print(a, "busy for {d} s with `{s}`", .{ (now -| sl.busy_since) / 1000, text.firstLine(a, sl.busy_command orelse "", 120) })
            else if (sl.process != null)
                "running, idle"
            else if (sl.starts == 0)
                "not started"
            else
                text.concat(a, &.{ "ended: ", sl.ended orelse "?" });
            out.print(a, "  {s}: {s}", .{ sl.kind.label(), state }) catch text.outOfMemory();
            if (sl.starts > 0) out.print(a, "; folder {s}; {d} command{s}; {s} {s}", .{ where(sl), sl.commands, if (sl.commands == 1) "" else "s", sl.kind.product(), sl.version orelse "" }) catch text.outOfMemory();
            out.append(a, '\n') catch text.outOfMemory();
        }
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

pub const RestartArgs = struct {
    kind: ?shell.Kind = null,
    stamen: ?[]const u8 = null,
    agent: ?[]const u8 = null,
};

/// Ends shells of one of the caller's stamens and starts them fresh where they were.
pub fn restart(s: *Session, a: Allocator, args: RestartArgs) Reply {
    var notes: Notes = .{ .a = a };
    const agent = agentOf(s, args.agent, &notes);
    if (args.stamen) |n| if (n.len > 0 and !validName(n)) return .{ .text = text.print(a, "\"{s}\" cannot name a stamen.", .{n}), .is_error = true };
    const id = stamenId(a, agent, args.stamen);
    var targets: std.ArrayList(*Slot) = .empty;
    var busy: std.ArrayList([]const u8) = .empty;
    win.AcquireSRWLockExclusive(&s.lock);
    const st = s.find(id) orelse {
        win.ReleaseSRWLockExclusive(&s.lock);
        return .{ .text = text.print(a, "There is no stamen {s} of yours to restart: it has not run a command.", .{id}), .is_error = true };
    };
    for (&st.slots) |*sl| {
        if (args.kind) |k| if (sl.kind != k) continue;
        if (args.kind == null and sl.process == null) continue;
        if (sl.busy) {
            busy.append(a, sl.kind.label()) catch text.outOfMemory();
            continue;
        }
        sl.busy = true;
        text.replace(&sl.busy_command, "(restarting)");
        sl.busy_since = clock.ms();
        text.replace(&sl.busy_since_clock, clock.stamp().clock(a));
        targets.append(a, sl) catch text.outOfMemory();
    }
    win.ReleaseSRWLockExclusive(&s.lock);

    var lines: std.ArrayList(u8) = .empty;
    for (targets.items) |sl| {
        endShell(s, a, st, sl, "the shell was restarted");
        var start_notes: Notes = .{ .a = a };
        switch (ensureStarted(s, a, st, sl, null, &start_notes)) {
            .failure => |failure| lines.print(a, "{s}: {s}\n", .{ sl.kind.label(), failure.text }) catch text.outOfMemory(),
            .process => |p| {
                p.release();
                lines.print(a, "{s}: restarted; {s}\n", .{ sl.kind.label(), start_notes.lines.items[0] }) catch text.outOfMemory();
            },
        }
        win.AcquireSRWLockExclusive(&s.lock);
        sl.busy = false;
        win.ReleaseSRWLockExclusive(&s.lock);
    }
    for (busy.items) |k| lines.print(a, "{s}: busy, so not restarted\n", .{k}) catch text.outOfMemory();
    if (targets.items.len == 0 and busy.items.len == 0) lines.appendSlice(a, "No shell of this stamen was running, so there was nothing to restart.") catch text.outOfMemory();
    return withNotes(a, .{ .text = text.concat(a, &.{ text.print(a, "stamen {s}:\n", .{st.id}), std.mem.trimEnd(u8, lines.items, "\n") }), .is_error = false }, &notes);
}

test readOutput {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = paths.join(a, &.{ paths.getEnv(a, "TEMP").?, "petal-readoutput-test.txt" });
    var big: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 5000) : (i += 1) big.print(a, "line {d:0>5} é\r\n", .{i}) catch unreachable;
    try std.testing.expect(paths.writeFile(a, path, big.items));
    const out = readOutput(a, path);
    _ = win.DeleteFileW(text.wide(a, path).ptr);
    try std.testing.expect(out.truncated);
    try std.testing.expectEqual(@as(usize, 5000), out.total_lines);
    try std.testing.expect(text.utf16Length(out.text) <= output_limit + 100);
    try std.testing.expect(std.mem.startsWith(u8, out.text, "line 00000 é\nline 00001 é\n"));
    try std.testing.expect(std.mem.endsWith(u8, out.text, "line 04999 é\n"));
    try std.testing.expect(std.mem.find(u8, out.text, "\r") == null);
    try std.testing.expect(std.mem.find(u8, out.text, "not shown") != null);
}

test validName {
    try std.testing.expect(validName("build-2.x_y"));
    try std.testing.expect(!validName("a:b"));
    try std.testing.expect(!validName(""));
    try std.testing.expect(!validName("é"));
}

test {
    std.testing.refAllDecls(@This());
}
