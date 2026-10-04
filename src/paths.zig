//! Where things are: the three shells, petal's data folder, the Claude Code that started petal,
//! and the small file helpers the rest of petal uses. Every location is derived from the
//! environment; none is written into the code.

const std = @import("std");
const win = @import("win.zig");
const text = @import("text.zig");

const Allocator = text.Allocator;

pub fn getEnv(a: Allocator, name: []const u8) ?[]u8 {
    const w = text.wide(a, name);
    const size = win.GetEnvironmentVariableW(w.ptr, null, 0);
    if (size == 0) return null;
    const buffer = a.alloc(u16, size) catch text.outOfMemory();
    const len = win.GetEnvironmentVariableW(w.ptr, buffer.ptr, size);
    if (len == 0 or len >= size) return null;
    return text.narrow(a, buffer[0..len]);
}

pub fn attributes(a: Allocator, path: []const u8) ?win.DWORD {
    const attrs = win.GetFileAttributesW(text.wide(a, path).ptr);
    if (attrs == win.INVALID_FILE_ATTRIBUTES) return null;
    return attrs;
}

pub fn isFile(a: Allocator, path: []const u8) bool {
    const attrs = attributes(a, path) orelse return false;
    return attrs & win.FILE_ATTRIBUTE_DIRECTORY == 0;
}

pub fn isDir(a: Allocator, path: []const u8) bool {
    const attrs = attributes(a, path) orelse return false;
    return attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0;
}

/// The path with "." and ".." resolved and its separators made backslashes.
pub fn full(a: Allocator, path: []const u8) []u8 {
    const w = text.wide(a, path);
    const buffer = a.alloc(u16, 32768) catch text.outOfMemory();
    const len = win.GetFullPathNameW(w.ptr, @intCast(buffer.len), buffer.ptr, null);
    if (len == 0 or len >= buffer.len) return text.dupe(a, path);
    return text.narrow(a, buffer[0..len]);
}

pub fn join(a: Allocator, parts: []const []const u8) []u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts, 0..) |part, i| {
        if (i > 0 and out.items.len > 0 and out.items[out.items.len - 1] != '\\' and out.items[out.items.len - 1] != '/') {
            out.append(a, '\\') catch text.outOfMemory();
        }
        out.appendSlice(a, part) catch text.outOfMemory();
    }
    return out.toOwnedSlice(a) catch text.outOfMemory();
}

pub fn dirname(path: []const u8) []const u8 {
    const end = std.mem.trimEnd(u8, path, "\\/");
    const i = std.mem.findLastAny(u8, end, "\\/") orelse return "";
    return end[0..i];
}

pub fn basename(path: []const u8) []const u8 {
    const end = std.mem.trimEnd(u8, path, "\\/");
    const i = std.mem.findLastAny(u8, end, "\\/") orelse return end;
    return end[i + 1 ..];
}

/// Creates the folder and any missing parents; true when the folder exists afterwards.
pub fn makeDirs(a: Allocator, path: []const u8) bool {
    if (isDir(a, path)) return true;
    const parent = dirname(path);
    if (parent.len > 0 and !std.mem.eql(u8, parent, path) and !isDir(a, parent)) {
        if (!makeDirs(a, parent)) return false;
    }
    _ = win.CreateDirectoryW(text.wide(a, path).ptr, null);
    return isDir(a, path);
}

pub fn currentDirectory(a: Allocator) []u8 {
    const buffer = a.alloc(u16, 32768) catch text.outOfMemory();
    const len = win.GetCurrentDirectoryW(@intCast(buffer.len), buffer.ptr);
    if (len == 0 or len >= buffer.len) return text.dupe(a, ".");
    return text.narrow(a, buffer[0..len]);
}

pub fn openRead(a: Allocator, path: []const u8) ?win.HANDLE {
    const h = win.CreateFileW(text.wide(a, path).ptr, win.GENERIC_READ, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return null;
    return h;
}

/// Up to `max` bytes from the handle's current position on: a file, or a pipe until it closes.
pub fn readAll(a: Allocator, h: win.HANDLE, max: usize) []u8 {
    var out: std.ArrayList(u8) = .empty;
    var chunk: [65536]u8 = undefined;
    while (out.items.len < max) {
        var n: win.DWORD = 0;
        const want: win.DWORD = @intCast(@min(chunk.len, max - out.items.len));
        if (!win.ReadFile(h, &chunk, want, &n, null).toBool() or n == 0) break;
        out.appendSlice(a, chunk[0..n]) catch text.outOfMemory();
    }
    return out.toOwnedSlice(a) catch text.outOfMemory();
}

pub fn readFile(a: Allocator, path: []const u8, max: usize) ?[]u8 {
    const h = openRead(a, path) orelse return null;
    defer win.CloseHandle(h);
    return readAll(a, h, max);
}

pub fn writeAll(h: win.HANDLE, bytes: []const u8) bool {
    var at: usize = 0;
    while (at < bytes.len) {
        var n: win.DWORD = 0;
        const want: win.DWORD = @intCast(@min(bytes.len - at, 1 << 30));
        if (!win.WriteFile(h, bytes[at..].ptr, want, &n, null).toBool() or n == 0) return false;
        at += n;
    }
    return true;
}

/// Writes the whole file at once: the bytes go to a temporary name first, then replace the file.
pub fn writeFile(a: Allocator, path: []const u8, bytes: []const u8) bool {
    const temporary = text.concat(a, &.{ path, ".tmp" });
    const h = win.CreateFileW(text.wide(a, temporary).ptr, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (h == win.INVALID_HANDLE_VALUE) return false;
    const ok = writeAll(h, bytes);
    win.CloseHandle(h);
    if (!ok) {
        _ = win.DeleteFileW(text.wide(a, temporary).ptr);
        return false;
    }
    return win.MoveFileExW(text.wide(a, temporary).ptr, text.wide(a, path).ptr, win.MOVEFILE_REPLACE_EXISTING).toBool();
}

/// The first file of this name in a folder on PATH.
pub fn searchPath(a: Allocator, name: []const u8) ?[]u8 {
    const path = getEnv(a, "PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ';');
    while (it.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \"");
        if (dir.len == 0) continue;
        const candidate = join(a, &.{ dir, name });
        if (isFile(a, candidate)) return full(a, candidate);
    }
    return null;
}

pub const Shells = struct {
    pwsh: ?[]u8 = null,
    powershell: ?[]u8 = null,
    /// Git for Windows' bin\bash.exe, which sets up Git Bash's environment and runs usr\bin\bash.exe.
    bash: ?[]u8 = null,
    /// usr\bin\bash.exe itself, for "bash -n", which needs no environment.
    bash_syntax: ?[]u8 = null,
};

pub fn findShells(a: Allocator) Shells {
    var shells: Shells = .{};
    shells.pwsh = searchPath(a, "pwsh.exe") orelse inFolder(a, "ProgramFiles", &.{ "PowerShell", "7", "pwsh.exe" });
    shells.powershell = inFolder(a, "SystemRoot", &.{ "System32", "WindowsPowerShell", "v1.0", "powershell.exe" });
    shells.bash = findGitBash(a);
    if (shells.bash) |bash| {
        const real = join(a, &.{ dirname(dirname(bash)), "usr", "bin", "bash.exe" });
        shells.bash_syntax = if (isFile(a, real)) real else bash;
    }
    return shells;
}

fn inFolder(a: Allocator, variable: []const u8, parts: []const []const u8) ?[]u8 {
    const base = getEnv(a, variable) orelse return null;
    var all: std.ArrayList([]const u8) = .empty;
    all.append(a, base) catch text.outOfMemory();
    all.appendSlice(a, parts) catch text.outOfMemory();
    const candidate = join(a, all.items);
    return if (isFile(a, candidate)) candidate else null;
}

// Git Bash, never the bash.exe of the Windows Subsystem for Linux that System32 holds: found the
// way Claude Code finds it, from CLAUDE_CODE_GIT_BASH_PATH, the Program Files folders, or the
// Git that PATH reaches.
fn findGitBash(a: Allocator) ?[]u8 {
    if (getEnv(a, "CLAUDE_CODE_GIT_BASH_PATH")) |configured| {
        if (std.ascii.eqlIgnoreCase(basename(configured), "bash.exe") and isFile(a, configured)) return full(a, configured);
    }
    if (inFolder(a, "ProgramFiles", &.{ "Git", "bin", "bash.exe" })) |found| return found;
    if (inFolder(a, "ProgramFiles(x86)", &.{ "Git", "bin", "bash.exe" })) |found| return found;
    const git = searchPath(a, "git.exe") orelse return null;
    const dir = dirname(git);
    for ([_][]const []const u8{ &.{ dir, "..", "bin", "bash.exe" }, &.{ dir, "..", "..", "bin", "bash.exe" } }) |parts| {
        const candidate = full(a, join(a, parts));
        if (isFile(a, candidate)) return candidate;
    }
    return null;
}

/// petal's data folder: PETAL_DATA_DIR when set, else .petal in the user's profile folder. Not under
/// %LOCALAPPDATA%: started by the Claude desktop app, petal runs inside the app's Windows package,
/// which keeps a folder created there in the package, out of sight of every program outside the app.
pub fn dataDir(a: Allocator) ?[]u8 {
    if (getEnv(a, "PETAL_DATA_DIR")) |dir| return dir;
    const profile = getEnv(a, "USERPROFILE") orelse return null;
    return join(a, &.{ profile, ".petal" });
}

/// The session's id as a folder name: Claude Code hands its id to the servers it starts.
pub fn sessionId(a: Allocator) []u8 {
    const raw = getEnv(a, "CLAUDE_CODE_SESSION_ID") orelse return text.print(a, "no-session-{d}", .{win.GetCurrentProcessId()});
    for (raw) |*c| {
        if (!(std.ascii.isAlphanumeric(c.*) or c.* == '-' or c.* == '_' or c.* == '.')) c.* = '_';
    }
    return raw;
}

/// The executable of the Claude Code that started petal, from the process id it hands over.
/// The executable of the Claude Code that started petal: the process CLAUDE_PID names, else
/// petal's parent process, whichever is a claude.exe. Claude Code sets CLAUDE_PID in its own
/// shell tools but not for the MCP servers it starts, which it starts itself, as their parent.
pub fn claudeExecutable(a: Allocator) ?[]u8 {
    if (getEnv(a, "CLAUDE_PID")) |pid_text| {
        if (std.fmt.parseInt(win.DWORD, pid_text, 10)) |pid| {
            if (claudeImage(a, pid)) |path| return path;
        } else |_| {}
    }
    const parent = parentProcessId() orelse return null;
    return claudeImage(a, parent);
}

/// The process's executable when it is a claude.exe.
fn claudeImage(a: Allocator, pid: win.DWORD) ?[]u8 {
    const process = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return null;
    defer win.CloseHandle(process);
    const buffer = a.alloc(u16, 32768) catch text.outOfMemory();
    var size: win.DWORD = @intCast(buffer.len);
    if (!win.QueryFullProcessImageNameW(process, 0, buffer.ptr, &size).toBool()) return null;
    const path = text.narrow(a, buffer[0..size]);
    if (!std.ascii.eqlIgnoreCase(basename(path), "claude.exe")) return null;
    return path;
}

/// The id of the process that started this one, from a snapshot of the system's processes.
fn parentProcessId() ?win.DWORD {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (snapshot == win.INVALID_HANDLE_VALUE) return null;
    defer win.CloseHandle(snapshot);
    const self = win.GetCurrentProcessId();
    var entry = std.mem.zeroes(win.PROCESSENTRY32W);
    entry.dwSize = @sizeOf(win.PROCESSENTRY32W);
    var more = win.Process32FirstW(snapshot, &entry).toBool();
    while (more) : (more = win.Process32NextW(snapshot, &entry).toBool()) {
        if (entry.th32ProcessID == self) return entry.th32ParentProcessID;
    }
    return null;
}

test parentProcessId {
    const parent = parentProcessId() orelse return error.NoParentFound;
    try std.testing.expect(parent != win.GetCurrentProcessId());
    const process = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, parent) orelse return error.ParentNotOpen;
    win.CloseHandle(process);
}

test "paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("C:\\a", dirname("C:\\a\\b.txt"));
    try std.testing.expectEqualStrings("b.txt", basename("C:\\a\\b.txt"));
    try std.testing.expectEqualStrings("C:\\a\\b", join(a, &.{ "C:\\a\\", "b" }));
    try std.testing.expectEqualStrings("C:\\x\\z", full(a, "C:\\x\\y\\..\\z"));
}
