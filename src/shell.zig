//! One shell process: started the way petal's probes proved, talked to through its loop script,
//! and ended together with everything it started.
//!
//! Each shell gets three pipes: requests from petal, answers to petal, and its own standard output
//! and error, which only a program that writes straight to them uses. PowerShell reads its requests
//! from a pipe whose handle number it is given, its standard input being NUL, because a program
//! started by a command inherits PowerShell's standard input and would read petal's requests. Bash
//! reads them from its standard input and gives every command /dev/null in its place. The shell and
//! all it starts run in a job object that ends them all when petal ends it or exits.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");
const clock = @import("clock.zig");
const Env = @import("env.zig").Env;

const Allocator = text.Allocator;
const lasting = text.lasting;

pub const Kind = enum {
    pwsh,
    powershell,
    bash,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .pwsh => "pwsh",
            .powershell => "powershell",
            .bash => "bash",
        };
    }

    pub fn product(k: Kind) []const u8 {
        return switch (k) {
            .pwsh => "PowerShell",
            .powershell => "Windows PowerShell",
            .bash => "Git Bash",
        };
    }

    pub fn parse(s: []const u8) ?Kind {
        inline for (@typeInfo(Kind).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const loop_powershell = @embedFile("loop.ps1");
pub const loop_bash = @embedFile("loop.sh");

const stray_limit = 64 * 1024;

/// An answer from the shell's loop. A PowerShell answer carries JSON; Bash's carry fields.
pub const Frame = struct {
    op: []const u8,
    id: u64,
    json: []const u8 = "",
    status: i64 = 0,
    fields: [3][]const u8 = .{ "", "", "" },
    values: []?[]const u8 = &.{},

    fn copy(f: Frame, a: Allocator) Frame {
        var c = f;
        c.op = text.dupe(a, f.op);
        c.json = text.dupe(a, f.json);
        for (&c.fields, f.fields) |*to, from| to.* = text.dupe(a, from);
        const values = a.alloc(?[]const u8, f.values.len) catch text.outOfMemory();
        for (values, f.values) |*to, from| to.* = if (from) |v| text.dupe(a, v) else null;
        c.values = values;
        return c;
    }

    fn free(f: Frame) void {
        lasting.free(f.op);
        lasting.free(f.json);
        for (f.fields) |field| lasting.free(field);
        for (f.values) |v| if (v) |value| lasting.free(value);
        lasting.free(f.values);
    }
};

/// Its holders: the slot that owns it, its two reader threads, and any call using it. Its handles
/// stay open until the last of them lets go, so no holder ever uses a handle that was closed.
pub const Process = struct {
    kind: Kind,
    refs: std.atomic.Value(u32) = .init(3),
    process: win.HANDLE,
    job: win.HANDLE,
    requests: win.HANDLE,
    answers: win.HANDLE,
    stray: win.HANDLE,
    pid: win.DWORD,
    started: clock.Stamp,
    version: []const u8 = "",
    lock: win.SRWLOCK = .{},
    frames: std.ArrayList(Frame) = .empty,
    frame_event: win.HANDLE,
    answers_closed: bool = false,
    stray_bytes: std.ArrayList(u8) = .empty,
    stray_dropped: usize = 0,
    /// The id of the last command whose marker arrived, and where in stray_bytes it was.
    stray_marker: u64 = 0,
    stray_cut: ?usize = null,
    stray_closed: bool = false,
    stray_event: win.HANDLE,
    ended: bool = false,

    pub fn retain(p: *Process) void {
        _ = p.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(p: *Process) void {
        if (p.refs.fetchSub(1, .acq_rel) != 1) return;
        win.CloseHandle(p.requests);
        win.CloseHandle(p.job);
        win.CloseHandle(p.process);
        win.CloseHandle(p.frame_event);
        win.CloseHandle(p.stray_event);
        for (p.frames.items) |f| f.free();
        p.frames.deinit(lasting);
        p.stray_bytes.deinit(lasting);
        lasting.free(p.version);
        lasting.destroy(p);
    }

    /// Ends the shell and everything it started, and waits for the shell to be gone.
    pub fn kill(p: *Process) void {
        _ = win.TerminateJobObject(p.job, 1);
        _ = win.WaitForSingleObject(p.process, 5000);
    }

    /// Ends the shell and everything it started, and lets go of it: for its owner, once.
    pub fn end(p: *Process) void {
        win.AcquireSRWLockExclusive(&p.lock);
        const already = p.ended;
        p.ended = true;
        win.ReleaseSRWLockExclusive(&p.lock);
        if (already) return;
        p.kill();
        p.release();
    }

    pub fn isRunning(p: *Process) bool {
        return win.WaitForSingleObject(p.process, 0) == win.WAIT_TIMEOUT;
    }

    pub fn exitCode(p: *Process) ?u32 {
        if (p.isRunning()) return null;
        var code: win.DWORD = 0;
        if (!win.GetExitCodeProcess(p.process, &code).toBool()) return null;
        return code;
    }

    /// The exit code once the process has ended, waiting up to `ms` for it to: Git's bin\bash.exe
    /// outlives the Bash it runs by a moment.
    pub fn exitCodeWithin(p: *Process, ms: win.DWORD) ?u32 {
        _ = win.WaitForSingleObject(p.process, ms);
        return p.exitCode();
    }

    pub fn send(p: *Process, bytes: []const u8) bool {
        var at: usize = 0;
        while (at < bytes.len) {
            var n: win.DWORD = 0;
            if (!win.WriteFile(p.requests, bytes[at..].ptr, @intCast(bytes.len - at), &n, null).toBool() or n == 0) return false;
            at += n;
        }
        return true;
    }

    pub const Stray = struct { bytes: []const u8, dropped: usize };

    /// What programs wrote to the shell's own standard output and error. Given `through`, the id of
    /// a command that finished, it waits up to `wait_ms` for that command's marker and takes what
    /// came before it; otherwise, or when the shell's output has closed, it takes all that came.
    pub fn takeStray(p: *Process, a: Allocator, through: ?u64, wait_ms: u64) Stray {
        const deadline = clock.ms() + wait_ms;
        win.AcquireSRWLockExclusive(&p.lock);
        defer win.ReleaseSRWLockExclusive(&p.lock);
        if (through) |id| while (p.stray_marker < id and !p.stray_closed) {
            const now = clock.ms();
            if (now >= deadline) break;
            win.ReleaseSRWLockExclusive(&p.lock);
            _ = win.WaitForSingleObject(p.stray_event, @intCast(@min(deadline - now, 1000)));
            win.AcquireSRWLockExclusive(&p.lock);
        };
        const reached = if (through) |id| p.stray_marker >= id else false;
        const end_at = if (reached) p.stray_cut orelse p.stray_bytes.items.len else p.stray_bytes.items.len;
        const bytes = text.dupe(a, p.stray_bytes.items[0..end_at]);
        const rest = p.stray_bytes.items.len - end_at;
        std.mem.copyForwards(u8, p.stray_bytes.items[0..rest], p.stray_bytes.items[end_at..]);
        p.stray_bytes.shrinkRetainingCapacity(rest);
        p.stray_cut = null;
        const dropped = p.stray_dropped;
        p.stray_dropped = 0;
        return .{ .bytes = bytes, .dropped = dropped };
    }

    pub const Wait = union(enum) {
        /// The answer, in the caller's allocator.
        frame: Frame,
        /// The shell's answer pipe closed: the shell ended.
        ended,
        cancelled,
        timed_out,
        /// Nothing yet; the caller may report progress and wait again.
        tick,
    };

    /// The answer with this id, or why there is none yet. Answers with other ids are dropped.
    pub fn wait(p: *Process, a: Allocator, id: u64, deadline: u64, cancel: ?win.HANDLE, tick_ms: u64) Wait {
        while (true) {
            win.AcquireSRWLockExclusive(&p.lock);
            var found: ?Frame = null;
            while (p.frames.items.len > 0) {
                const f = p.frames.orderedRemove(0);
                if (f.id == id) {
                    found = f.copy(a);
                    f.free();
                    break;
                }
                f.free();
            }
            const closed = p.answers_closed;
            win.ReleaseSRWLockExclusive(&p.lock);
            if (found) |f| return .{ .frame = f };
            if (closed) return .ended;

            const now = clock.ms();
            if (now >= deadline) return .timed_out;
            const wait_ms: win.DWORD = @intCast(@min(deadline - now, tick_ms));
            var handles: [2]win.HANDLE = .{ p.frame_event, undefined };
            var count: win.DWORD = 1;
            if (cancel) |c| {
                handles[1] = c;
                count = 2;
            }
            const r = win.WaitForMultipleObjects(count, &handles, .FALSE, wait_ms);
            if (r == win.WAIT_OBJECT_0 + 1) return .cancelled;
            if (r == win.WAIT_TIMEOUT) {
                if (clock.ms() >= deadline) return .timed_out;
                return .tick;
            }
        }
    }
};

pub const StartError = error{ CannotStart, NotReady };

/// Starts the shell in `folder` with `base_env`, and waits for its loop to report that it is
/// ready. Temporary memory and the diagnostic, when it fails, come from `a`.
pub fn start(a: Allocator, kind: Kind, exe: []const u8, folder: ?[]const u8, base_env: *const Env, diagnostic: *[]const u8) StartError!*Process {
    diagnostic.* = "";
    const requests = pipe() orelse return error.CannotStart;
    const answers = pipe() orelse return error.CannotStart;
    const stray = pipe() orelse return error.CannotStart;
    const nul = win.CreateFileW(std.unicode.utf8ToUtf16LeStringLiteral("NUL"), win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, null, win.OPEN_EXISTING, 0, null);
    if (nul == win.INVALID_HANDLE_VALUE) return error.CannotStart;
    for ([_]win.HANDLE{ requests.read, answers.write, stray.write, nul }) |h| {
        _ = win.SetHandleInformation(h, win.HANDLE_FLAG_INHERIT, win.HANDLE_FLAG_INHERIT);
    }

    var env = base_env.clone(a);
    removeControlVariables(&env);
    var si = std.mem.zeroes(win.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
    si.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES;
    var inherit: [4]win.HANDLE = undefined;
    var inherit_count: usize = 0;
    var command_line: []const u8 = undefined;
    switch (kind) {
        .bash => {
            si.StartupInfo.hStdInput = requests.read;
            si.StartupInfo.hStdOutput = answers.write;
            si.StartupInfo.hStdError = stray.write;
            inherit = .{ requests.read, answers.write, stray.write, undefined };
            inherit_count = 3;
            env.set("PETAL_LOOP", loop_bash);
            command_line = text.print(a, "\"{s}\" --noprofile --norc -c \"eval \\\"$PETAL_LOOP\\\"\"", .{exe});
        },
        .pwsh, .powershell => {
            si.StartupInfo.hStdInput = nul;
            si.StartupInfo.hStdOutput = stray.write;
            si.StartupInfo.hStdError = stray.write;
            inherit = .{ nul, stray.write, requests.read, answers.write };
            inherit_count = 4;
            env.set("PETAL_LOOP", loop_powershell);
            env.set("PETAL_IN", text.print(a, "{d}", .{@intFromPtr(requests.read)}));
            env.set("PETAL_OUT", text.print(a, "{d}", .{@intFromPtr(answers.write)}));
            command_line = text.print(a, "\"{s}\" -NoLogo -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand {s}", .{ exe, encodedBootstrap(a) });
        },
    }
    const block = env.block();

    var attr_size: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attr_size);
    const attr = a.alignedAlloc(u8, .of(usize), attr_size) catch text.outOfMemory();
    if (!win.InitializeProcThreadAttributeList(attr.ptr, 1, 0, &attr_size).toBool()) return error.CannotStart;
    defer win.DeleteProcThreadAttributeList(attr.ptr);
    if (!win.UpdateProcThreadAttribute(attr.ptr, 0, win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &inherit, inherit_count * @sizeOf(win.HANDLE), null, null).toBool()) return error.CannotStart;
    si.lpAttributeList = attr.ptr;

    const job = win.CreateJobObjectW(null, null) orelse return error.CannotStart;
    var limits = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
    limits.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!win.SetInformationJobObject(job, win.JobObjectExtendedLimitInformation, &limits, @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)).toBool()) {
        win.CloseHandle(job);
        return error.CannotStart;
    }

    const folder_w: ?[:0]u16 = if (folder) |f| text.wide(a, f) else null;
    var info: win.PROCESS_INFORMATION = undefined;
    const flags: win.CreateProcessFlags = .{ .create_suspended = true, .create_no_window = true, .create_unicode_environment = true, .extended_startupinfo_present = true };
    const created = win.CreateProcessW(text.wide(a, exe).ptr, text.wide(a, command_line).ptr, null, null, .TRUE, flags, block.ptr, if (folder_w) |f| f.ptr else null, &si.StartupInfo, &info).toBool();
    const create_error = win.GetLastError();
    win.CloseHandle(requests.read);
    win.CloseHandle(answers.write);
    win.CloseHandle(stray.write);
    win.CloseHandle(nul);
    if (!created) {
        diagnostic.* = text.print(a, "Windows error {d} starting {s}", .{ @intFromEnum(create_error), exe });
        win.CloseHandle(requests.write);
        win.CloseHandle(answers.read);
        win.CloseHandle(stray.read);
        win.CloseHandle(job);
        return error.CannotStart;
    }
    // A shell outside the job could outlive petal and a timeout; it must not run unless it is in.
    if (!win.AssignProcessToJobObject(job, info.hProcess).toBool()) {
        diagnostic.* = text.print(a, "Windows error {d} placing {s} in a job object", .{ @intFromEnum(win.GetLastError()), exe });
        _ = win.TerminateProcess(info.hProcess, 1);
        win.CloseHandle(info.hThread);
        win.CloseHandle(info.hProcess);
        win.CloseHandle(requests.write);
        win.CloseHandle(answers.read);
        win.CloseHandle(stray.read);
        win.CloseHandle(job);
        return error.CannotStart;
    }
    _ = win.ResumeThread(info.hThread);
    win.CloseHandle(info.hThread);

    const p = lasting.create(Process) catch text.outOfMemory();
    p.* = .{
        .kind = kind,
        .process = info.hProcess,
        .job = job,
        .requests = requests.write,
        .answers = answers.read,
        .stray = stray.read,
        .pid = info.dwProcessId,
        .started = clock.stamp(),
        .frame_event = win.CreateEventW(null, .FALSE, .FALSE, null) orelse text.outOfMemory(),
        .stray_event = win.CreateEventW(null, .FALSE, .FALSE, null) orelse text.outOfMemory(),
    };
    const reader = std.Thread.spawn(.{ .stack_size = 1 << 20 }, readAnswers, .{p}) catch {
        win.CloseHandle(p.answers);
        win.CloseHandle(p.stray);
        p.refs.store(1, .release);
        p.end();
        return error.CannotStart;
    };
    reader.detach();
    const strays = std.Thread.spawn(.{ .stack_size = 1 << 20 }, readStray, .{p}) catch {
        win.CloseHandle(p.stray);
        p.refs.store(2, .release);
        p.end();
        return error.CannotStart;
    };
    strays.detach();

    switch (p.wait(a, 0, clock.ms() + 60_000, null, 60_000)) {
        .frame => |f| {
            p.version = text.dupe(lasting, if (kind == .bash) f.fields[0] else versionFromJson(a, f.json));
            return p;
        },
        else => {
            p.kill();
            const stray_now = p.takeStray(a, std.math.maxInt(u64), 2000);
            p.end();
            diagnostic.* = if (stray_now.bytes.len > 0) text.cleanOutput(a, stray_now.bytes) else "it ended or stayed silent before its loop reported that it was ready";
            return error.NotReady;
        },
    }
}

/// The variables petal hands a starting shell's loop, which the loop removes once it has read them.
pub fn removeControlVariables(env: *Env) void {
    env.remove("PETAL_LOOP");
    env.remove("PETAL_IN");
    env.remove("PETAL_OUT");
}

fn encodedBootstrap(a: Allocator) []u8 {
    const boot = std.unicode.utf8ToUtf16LeStringLiteral(". ([ScriptBlock]::Create($env:PETAL_LOOP))");
    const bytes = std.mem.sliceAsBytes(boot[0..boot.len]);
    const out = a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len)) catch text.outOfMemory();
    _ = std.base64.standard.Encoder.encode(out, bytes);
    return out;
}

fn versionFromJson(a: Allocator, json: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{}) catch return "";
    if (parsed != .object) return "";
    const v = parsed.object.get("version") orelse return "";
    return if (v == .string) v.string else "";
}

const Pipe = struct { read: win.HANDLE, write: win.HANDLE };

fn pipe() ?Pipe {
    var r: win.HANDLE = undefined;
    var w: win.HANDLE = undefined;
    if (!win.CreatePipe(&r, &w, null, 65536).toBool()) return null;
    return .{ .read = r, .write = w };
}

/// Reads the answers pipe, a byte stream that may split an answer anywhere. What it returns is
/// lasting memory, owned by the frame it becomes.
const ByteReader = struct {
    h: win.HANDLE,
    buffer: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(r: *ByteReader) bool {
        var n: win.DWORD = 0;
        if (!win.ReadFile(r.h, &r.buffer, r.buffer.len, &n, null).toBool() or n == 0) return false;
        r.start = 0;
        r.end = n;
        return true;
    }

    fn line(r: *ByteReader) ?[]u8 {
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (r.start == r.end and !r.fill()) {
                out.deinit(lasting);
                return null;
            }
            const b = r.buffer[r.start];
            r.start += 1;
            if (b == '\n') return out.toOwnedSlice(lasting) catch text.outOfMemory();
            out.append(lasting, b) catch text.outOfMemory();
        }
    }

    fn bytes(r: *ByteReader, n: usize) ?[]u8 {
        const out = lasting.alloc(u8, n) catch text.outOfMemory();
        var at: usize = 0;
        while (at < n) {
            if (r.start == r.end and !r.fill()) {
                lasting.free(out);
                return null;
            }
            const take = @min(n - at, r.end - r.start);
            @memcpy(out[at .. at + take], r.buffer[r.start .. r.start + take]);
            r.start += take;
            at += take;
        }
        return out;
    }
};

fn number(s: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, s orelse return null, 10) catch null;
}

fn readAnswers(p: *Process) void {
    var r = ByteReader{ .h = p.answers };
    while (true) {
        const frame = readFrame(p.kind, &r) orelse break;
        win.AcquireSRWLockExclusive(&p.lock);
        p.frames.append(lasting, frame) catch text.outOfMemory();
        win.ReleaseSRWLockExclusive(&p.lock);
        _ = win.SetEvent(p.frame_event);
    }
    win.AcquireSRWLockExclusive(&p.lock);
    p.answers_closed = true;
    win.ReleaseSRWLockExclusive(&p.lock);
    _ = win.SetEvent(p.frame_event);
    win.CloseHandle(p.answers);
    p.release();
}

/// One answer, or null when the pipe closed or the answer was malformed.
fn readFrame(kind: Kind, r: *ByteReader) ?Frame {
    const header = r.line() orelse return null;
    defer lasting.free(header);
    var it = std.mem.splitScalar(u8, header, ' ');
    const op = it.next() orelse return null;
    const id = number(it.next()) orelse return null;
    var f = Frame{ .op = text.dupe(lasting, op), .id = id, .json = text.dupe(lasting, ""), .fields = .{ text.dupe(lasting, ""), text.dupe(lasting, ""), text.dupe(lasting, "") }, .values = lasting.alloc(?[]const u8, 0) catch text.outOfMemory() };
    var ok = true;
    if (kind != .bash or std.mem.eql(u8, op, "ready")) {
        if (number(it.next())) |len| {
            if (r.bytes(len)) |payload| {
                if (kind == .bash) {
                    lasting.free(f.fields[0]);
                    f.fields[0] = payload;
                } else {
                    lasting.free(f.json);
                    f.json = payload;
                }
            } else ok = false;
        } else ok = false;
    } else if (std.mem.eql(u8, op, "done")) {
        if (std.fmt.parseInt(i64, it.next() orelse "", 10)) |status| {
            f.status = status;
            for (&f.fields) |*field| {
                const len = number(it.next()) orelse {
                    ok = false;
                    break;
                };
                const payload = r.bytes(len) orelse {
                    ok = false;
                    break;
                };
                lasting.free(field.*);
                field.* = payload;
            }
        } else |_| ok = false;
    } else if (std.mem.eql(u8, op, "resolved")) {
        if (number(it.next())) |count| {
            const values = lasting.alloc(?[]const u8, count) catch text.outOfMemory();
            @memset(values, null);
            lasting.free(f.values);
            f.values = values;
            for (values) |*v| {
                const len_line = r.line() orelse {
                    ok = false;
                    break;
                };
                const len = std.fmt.parseInt(i64, len_line, 10) catch -2;
                lasting.free(len_line);
                if (len == -2) {
                    ok = false;
                    break;
                }
                if (len >= 0) v.* = r.bytes(@intCast(len)) orelse {
                    ok = false;
                    break;
                };
            }
        } else ok = false;
    }
    if (!ok) {
        f.free();
        return null;
    }
    return f;
}

fn readStray(p: *Process) void {
    var chunk: [4096]u8 = undefined;
    var parser: StrayParser = .{};
    defer parser.held.deinit(lasting);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(lasting);
    while (true) {
        var n: win.DWORD = 0;
        const got = win.ReadFile(p.stray, &chunk, chunk.len, &n, null).toBool() and n > 0;
        output.clearRetainingCapacity();
        var fed: StrayParser.Fed = .{};
        if (got) fed = parser.feed(chunk[0..n], &output) else parser.flush(&output);
        win.AcquireSRWLockExclusive(&p.lock);
        const base = p.stray_bytes.items.len;
        const keep = @min(stray_limit -| base, output.items.len);
        p.stray_bytes.appendSlice(lasting, output.items[0..keep]) catch text.outOfMemory();
        p.stray_dropped += output.items.len - keep;
        if (fed.marker) |m| {
            p.stray_marker = m;
            p.stray_cut = @min(base + fed.cut, p.stray_bytes.items.len);
        }
        if (!got) p.stray_closed = true;
        win.ReleaseSRWLockExclusive(&p.lock);
        if (fed.marker != null or !got) _ = win.SetEvent(p.stray_event);
        if (!got) break;
    }
    win.CloseHandle(p.stray);
    p.release();
}

/// The marker a loop writes to the shell's own output after each command, followed by the
/// command's id and a newline. A program could only fake one by writing a NUL and these words.
const marker_prefix = "\x00petal-stray ";
const marker_max = marker_prefix.len + 20 + 1;

/// Splits the shell's own output into what programs wrote and the loops' markers, which a read
/// may split anywhere.
const StrayParser = struct {
    /// What came after the last whole piece: the start of a marker, perhaps.
    held: std.ArrayList(u8) = .empty,

    const Fed = struct { marker: ?u64 = null, cut: usize = 0 };

    /// Appends what programs wrote to `out`; returns the last marker's id and where in `out` it was.
    fn feed(sp: *StrayParser, bytes: []const u8, out: *std.ArrayList(u8)) Fed {
        sp.held.appendSlice(lasting, bytes) catch text.outOfMemory();
        const all = sp.held.items;
        var fed: Fed = .{};
        var from: usize = 0;
        var i: usize = 0;
        var hold_from = all.len;
        while (std.mem.findScalarPos(u8, all, i, 0)) |z| {
            const rest = all[z..];
            const n = @min(rest.len, marker_prefix.len);
            if (!std.mem.eql(u8, rest[0..n], marker_prefix[0..n])) {
                i = z + 1;
                continue;
            }
            const nl = std.mem.findScalar(u8, rest[0..@min(rest.len, marker_max)], '\n') orelse {
                if (rest.len < marker_max) {
                    hold_from = z;
                    break;
                }
                i = z + 1;
                continue;
            };
            const id = std.fmt.parseInt(u64, rest[marker_prefix.len..nl], 10) catch {
                i = z + 1;
                continue;
            };
            out.appendSlice(lasting, all[from..z]) catch text.outOfMemory();
            fed = .{ .marker = id, .cut = out.items.len };
            i = z + nl + 1;
            from = i;
        }
        out.appendSlice(lasting, all[from..hold_from]) catch text.outOfMemory();
        const kept = all.len - hold_from;
        std.mem.copyForwards(u8, sp.held.items[0..kept], all[hold_from..]);
        sp.held.shrinkRetainingCapacity(kept);
        return fed;
    }

    /// The output closed: what was held was no marker.
    fn flush(sp: *StrayParser, out: *std.ArrayList(u8)) void {
        out.appendSlice(lasting, sp.held.items) catch text.outOfMemory();
        sp.held.clearRetainingCapacity();
    }
};

test StrayParser {
    const t = std.testing;
    const whole = "before\r\n\x00petal-stray 17\nafter \x00 a NUL\n\x00petal-stray 18\n\x00petal-st";
    // Every way of splitting the stream into two reads gives the same result.
    var split: usize = 0;
    while (split <= whole.len) : (split += 1) {
        var sp: StrayParser = .{};
        defer sp.held.deinit(lasting);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(lasting);
        const first = sp.feed(whole[0..split], &out);
        const second = sp.feed(whole[split..], &out);
        const last = second.marker orelse first.marker;
        try t.expectEqual(@as(?u64, 18), last);
        const cut = if (second.marker != null) second.cut else first.cut;
        try t.expectEqualStrings("before\r\nafter \x00 a NUL\n", out.items[0..cut]);
        try t.expectEqualStrings("before\r\nafter \x00 a NUL\n", out.items);
        sp.flush(&out);
        try t.expectEqualStrings("before\r\nafter \x00 a NUL\n\x00petal-st", out.items);
    }
    var sp: StrayParser = .{};
    defer sp.held.deinit(lasting);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(lasting);
    try t.expectEqual(@as(?u64, null), sp.feed("\x00petal-stray notanumber\nx", &out).marker);
    try t.expectEqualStrings("\x00petal-stray notanumber\nx", out.items);
}

/// A request line for the Bash loop: every byte outside printable ASCII, and every backslash,
/// written as \xHH, which the loop's printf '%b' turns back into the same bytes.
pub fn bashLine(a: Allocator, op: []const u8, id: u64, payload: []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{s} {d} ", .{ op, id }) catch text.outOfMemory();
    for (payload) |c| {
        if (c >= 0x20 and c < 0x7f and c != '\\') {
            out.append(a, c) catch text.outOfMemory();
        } else {
            out.print(a, "\\x{x:0>2}", .{c}) catch text.outOfMemory();
        }
    }
    out.append(a, '\n') catch text.outOfMemory();
    return out.items;
}

/// A request for the PowerShell loop: a header line, then the JSON payload.
pub fn powershellRequest(a: Allocator, op: []const u8, id: u64, json: []const u8) []u8 {
    return text.concat(a, &.{ text.print(a, "{s} {d} {d}\n", .{ op, id, json.len }), json });
}

test bashLine {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("run 3 a\\x5cb\\x0ac\\xc3\\xa9\n", bashLine(arena.allocator(), "run", 3, "a\\b\nc\u{e9}"));
}

test {
    std.testing.refAllDecls(@This());
}
