//! The check before running, for Bash. Whether the command parses comes from Bash itself
//! (bash -n). The two deletion rules need the command's words, which Bash cannot hand over, so a
//! small reader below splits the command into simple commands and words the way Bash does for the
//! cases the rules need: quotes, escapes, $name and ${name}, expansions that would run code,
//! redirections, here-documents and comments. It is the weaker of petal's two checks.

const std = @import("std");
const text = @import("text.zig");

const Allocator = text.Allocator;

pub const Part = union(enum) {
    literal: []const u8,
    /// A plain $name or ${name}: its value can be read without running code.
    variable: []const u8,
    /// Any other expansion: $(...), `...`, $((...)), ${name...} with an operator, $1, $@, ...
    other: []const u8,
};

pub const Word = struct {
    parts: []Part,
    raw: []const u8,
};

pub const Command = struct {
    words: []Word,
    line: u32,
    raw: []const u8,
};

pub const Reading = struct {
    commands: []Command,
};

pub fn read(a: Allocator, source: []const u8) Reading {
    var r = Reader{ .a = a, .s = source };
    r.run();
    return .{ .commands = r.commands.items };
}

const Reader = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,
    line: u32 = 1,
    commands: std.ArrayList(Command) = .empty,
    words: std.ArrayList(Word) = .empty,
    command_line: u32 = 1,
    command_start: usize = 0,
    heredocs: std.ArrayList(Heredoc) = .empty,
    skip_next_word: bool = false,

    const Heredoc = struct { delimiter: []const u8, strip_tabs: bool };

    fn peek(r: *Reader, ahead: usize) u8 {
        return if (r.i + ahead < r.s.len) r.s[r.i + ahead] else 0;
    }

    fn run(r: *Reader) void {
        while (r.i < r.s.len) {
            const c = r.s[r.i];
            switch (c) {
                ' ', '\t', '\r' => r.i += 1,
                '\n' => {
                    r.i += 1;
                    r.line += 1;
                    r.endCommand();
                    r.skipHeredocs();
                },
                '#' => while (r.i < r.s.len and r.s[r.i] != '\n') : (r.i += 1) {},
                ';', '&', '|', '(', ')' => {
                    r.i += 1;
                    if (r.i < r.s.len and (r.s[r.i] == c or (c == '|' and r.s[r.i] == '&'))) r.i += 1;
                    r.endCommand();
                },
                '<', '>' => r.redirection(),
                '\\' => {
                    if (r.peek(1) == '\n') {
                        r.i += 2;
                        r.line += 1;
                    } else {
                        r.word();
                    }
                },
                '0'...'9' => {
                    var j = r.i;
                    while (j < r.s.len and std.ascii.isDigit(r.s[j])) j += 1;
                    if (j < r.s.len and (r.s[j] == '<' or r.s[j] == '>')) {
                        r.i = j;
                        r.redirection();
                    } else {
                        r.word();
                    }
                },
                else => r.word(),
            }
        }
        r.endCommand();
    }

    fn redirection(r: *Reader) void {
        const start = r.i;
        while (r.i < r.s.len and (r.s[r.i] == '<' or r.s[r.i] == '>' or r.s[r.i] == '&' or r.s[r.i] == '|' or r.s[r.i] == '-')) : (r.i += 1) {}
        const op = r.s[start..r.i];
        if (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, "<<-")) {
            while (r.i < r.s.len and (r.s[r.i] == ' ' or r.s[r.i] == '\t')) r.i += 1;
            const delimiter_word = r.wordText();
            r.heredocs.append(r.a, .{ .delimiter = unquoted(r.a, delimiter_word), .strip_tabs = op.len == 3 }) catch text.outOfMemory();
            return;
        }
        if (std.mem.endsWith(u8, op, "&") and r.i < r.s.len and (std.ascii.isDigit(r.s[r.i]) or r.s[r.i] == '-')) {
            while (r.i < r.s.len and (std.ascii.isDigit(r.s[r.i]) or r.s[r.i] == '-')) r.i += 1;
            return;
        }
        r.skip_next_word = true;
    }

    fn skipHeredocs(r: *Reader) void {
        for (r.heredocs.items) |h| {
            while (r.i < r.s.len) {
                const end = std.mem.findScalarPos(u8, r.s, r.i, '\n') orelse r.s.len;
                var body_line = r.s[r.i..end];
                body_line = std.mem.trimEnd(u8, body_line, "\r");
                if (h.strip_tabs) body_line = std.mem.trimStart(u8, body_line, "\t");
                r.i = if (end < r.s.len) end + 1 else end;
                r.line += 1;
                if (std.mem.eql(u8, body_line, h.delimiter)) break;
            }
        }
        r.heredocs.clearRetainingCapacity();
    }

    fn endCommand(r: *Reader) void {
        if (r.words.items.len > 0) {
            r.commands.append(r.a, .{
                .words = r.words.toOwnedSlice(r.a) catch text.outOfMemory(),
                .line = r.command_line,
                .raw = std.mem.trim(u8, r.s[r.command_start..@min(r.i, r.s.len)], " \t\r\n;&|()"),
            }) catch text.outOfMemory();
        }
        r.words = .empty;
        r.skip_next_word = false;
    }

    fn wordText(r: *Reader) []const u8 {
        const start = r.i;
        _ = r.parts();
        return r.s[start..r.i];
    }

    fn word(r: *Reader) void {
        if (r.words.items.len == 0) {
            r.command_line = r.line;
            r.command_start = r.i;
        }
        const start = r.i;
        const ps = r.parts();
        if (r.skip_next_word) {
            r.skip_next_word = false;
            return;
        }
        r.words.append(r.a, .{ .parts = ps, .raw = r.s[start..r.i] }) catch text.outOfMemory();
    }

    fn isWordEnd(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n', ';', '&', '|', '(', ')', '<', '>' => true,
            else => false,
        };
    }

    fn parts(r: *Reader) []Part {
        var ps: std.ArrayList(Part) = .empty;
        var literal: std.ArrayList(u8) = .empty;
        while (r.i < r.s.len and !isWordEnd(r.s[r.i])) {
            const c = r.s[r.i];
            switch (c) {
                '\'' => {
                    const end = std.mem.findScalarPos(u8, r.s, r.i + 1, '\'') orelse r.s.len;
                    r.countLines(r.i + 1, end);
                    literal.appendSlice(r.a, r.s[r.i + 1 .. end]) catch text.outOfMemory();
                    r.i = @min(end + 1, r.s.len);
                },
                '"' => {
                    r.i += 1;
                    while (r.i < r.s.len and r.s[r.i] != '"') {
                        const d = r.s[r.i];
                        if (d == '\\' and r.i + 1 < r.s.len and std.mem.findScalar(u8, "$`\"\\\n", r.s[r.i + 1]) != null) {
                            if (r.s[r.i + 1] == '\n') r.line += 1 else literal.append(r.a, r.s[r.i + 1]) catch text.outOfMemory();
                            r.i += 2;
                        } else if (d == '$' or d == '`') {
                            r.expansion(&ps, &literal);
                        } else {
                            if (d == '\n') r.line += 1;
                            literal.append(r.a, d) catch text.outOfMemory();
                            r.i += 1;
                        }
                    }
                    r.i = @min(r.i + 1, r.s.len);
                },
                '\\' => {
                    if (r.i + 1 < r.s.len) {
                        if (r.s[r.i + 1] == '\n') r.line += 1 else literal.append(r.a, r.s[r.i + 1]) catch text.outOfMemory();
                        r.i += 2;
                    } else {
                        r.i += 1;
                    }
                },
                '$', '`' => r.expansion(&ps, &literal),
                else => {
                    literal.append(r.a, c) catch text.outOfMemory();
                    r.i += 1;
                },
            }
        }
        flush(r.a, &ps, &literal);
        return ps.items;
    }

    fn countLines(r: *Reader, from: usize, to: usize) void {
        r.line += @intCast(std.mem.count(u8, r.s[from..@min(to, r.s.len)], "\n"));
    }

    fn flush(a: Allocator, ps: *std.ArrayList(Part), literal: *std.ArrayList(u8)) void {
        if (literal.items.len == 0) return;
        ps.append(a, .{ .literal = literal.toOwnedSlice(a) catch text.outOfMemory() }) catch text.outOfMemory();
    }

    fn expansion(r: *Reader, ps: *std.ArrayList(Part), literal: *std.ArrayList(u8)) void {
        const start = r.i;
        if (r.s[r.i] == '`') {
            var j = r.i + 1;
            while (j < r.s.len and r.s[j] != '`') : (j += 1) {
                if (r.s[j] == '\\') j += 1;
            }
            r.countLines(r.i, j);
            r.i = @min(j + 1, r.s.len);
            flush(r.a, ps, literal);
            ps.append(r.a, .{ .other = r.s[start..r.i] }) catch text.outOfMemory();
            return;
        }
        const next = r.peek(1);
        if (next == '(') {
            r.i = r.matching(r.i + 1, '(', ')');
            flush(r.a, ps, literal);
            ps.append(r.a, .{ .other = r.s[start..r.i] }) catch text.outOfMemory();
            return;
        }
        if (next == '{') {
            const end = r.matching(r.i + 1, '{', '}');
            const closed = end >= r.i + 3 and r.s[end - 1] == '}';
            const inner = if (closed) r.s[r.i + 2 .. end - 1] else "";
            r.i = end;
            flush(r.a, ps, literal);
            if (closed and isName(inner)) {
                ps.append(r.a, .{ .variable = inner }) catch text.outOfMemory();
            } else {
                ps.append(r.a, .{ .other = r.s[start..r.i] }) catch text.outOfMemory();
            }
            return;
        }
        if (next == '\'' or next == '"') {
            r.i += 1;
            return;
        }
        if (std.ascii.isAlphabetic(next) or next == '_') {
            var j = r.i + 1;
            while (j < r.s.len and (std.ascii.isAlphanumeric(r.s[j]) or r.s[j] == '_')) j += 1;
            const name = r.s[r.i + 1 .. j];
            r.i = j;
            flush(r.a, ps, literal);
            if (std.mem.eql(u8, name, "_")) {
                ps.append(r.a, .{ .other = r.s[start..r.i] }) catch text.outOfMemory();
            } else {
                ps.append(r.a, .{ .variable = name }) catch text.outOfMemory();
            }
            return;
        }
        if (next != 0 and std.mem.findScalar(u8, "@*#?-$!0123456789", next) != null) {
            r.i += 2;
            flush(r.a, ps, literal);
            ps.append(r.a, .{ .other = r.s[start..r.i] }) catch text.outOfMemory();
            return;
        }
        literal.append(r.a, '$') catch text.outOfMemory();
        r.i += 1;
    }

    /// The index just past the bracket that closes the one at `open_at`.
    fn matching(r: *Reader, open_at: usize, open: u8, close: u8) usize {
        var depth: usize = 0;
        var j = open_at;
        while (j < r.s.len) : (j += 1) {
            const c = r.s[j];
            if (c == '\\') {
                j += 1;
            } else if (c == '\'' and open == '(') {
                j = std.mem.findScalarPos(u8, r.s, j + 1, '\'') orelse r.s.len;
            } else if (c == open) {
                depth += 1;
            } else if (c == close) {
                depth -= 1;
                if (depth == 0) {
                    r.countLines(open_at, j);
                    return j + 1;
                }
            }
        }
        r.countLines(open_at, r.s.len);
        return r.s.len;
    }
};

fn isName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn unquoted(a: Allocator, raw: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        if (c != '\'' and c != '"' and c != '\\') out.append(a, c) catch text.outOfMemory();
    }
    return out.items;
}

/// The word as plain text when it has no expansions.
pub fn literalText(a: Allocator, w: Word) ?[]const u8 {
    if (w.parts.len == 1 and w.parts[0] == .literal) return w.parts[0].literal;
    var out: std.ArrayList(u8) = .empty;
    for (w.parts) |p| switch (p) {
        .literal => |l| out.appendSlice(a, l) catch text.outOfMemory(),
        else => return null,
    };
    return out.items;
}

const keywords = [_][]const u8{ "if", "then", "else", "elif", "do", "while", "until", "!", "{", "time", "coproc" };
const prefixes = [_][]const u8{ "command", "builtin", "exec", "nohup", "time", "nice", "sudo", "doas" };

pub const Deletion = struct {
    command: Command,
    targets: []Word,
};

pub const Deletions = struct {
    list: []Deletion,
    /// Names the command gives values to itself, whose value before it runs says nothing.
    assigned: [][]const u8,
};

/// Every rm, rmdir and unlink in the command with the words it would delete, and the names the
/// command assigns along the way.
pub fn deletions(a: Allocator, reading: Reading) Deletions {
    var out: std.ArrayList(Deletion) = .empty;
    var assigned: std.ArrayList([]const u8) = .empty;
    for (reading.commands) |c| {
        var words = c.words;
        while (words.len > 0) {
            const first = literalText(a, words[0]) orelse break;
            if (isAssignment(words[0].raw)) {
                assigned.append(a, words[0].raw[0..std.mem.findScalar(u8, words[0].raw, '=').?]) catch text.outOfMemory();
                words = words[1..];
                continue;
            }
            if (inList(first, &keywords) or inList(first, &prefixes)) {
                words = words[1..];
                continue;
            }
            if (std.mem.eql(u8, first, "env")) {
                words = words[1..];
                while (words.len > 0 and isAssignment(words[0].raw)) words = words[1..];
                continue;
            }
            break;
        }
        if (words.len == 0) continue;
        const name = literalText(a, words[0]) orelse continue;
        const base = baseName(name);
        if (std.mem.eql(u8, base, "for") or std.mem.eql(u8, base, "select")) {
            if (words.len > 1) if (literalText(a, words[1])) |v| assigned.append(a, v) catch text.outOfMemory();
            continue;
        }
        if (inList(base, &.{ "read", "mapfile", "readarray", "local", "declare", "typeset", "export", "readonly", "getopts", "let" })) {
            for (words[1..]) |w| {
                const t = literalText(a, w) orelse continue;
                if (t.len == 0 or t[0] == '-') continue;
                const eq = std.mem.findScalar(u8, t, '=') orelse t.len;
                if (isName(t[0..eq])) assigned.append(a, t[0..eq]) catch text.outOfMemory();
            }
            continue;
        }
        if (std.mem.eql(u8, base, "printf")) {
            for (words[1..], 0..) |w, k| {
                if (std.mem.eql(u8, literalText(a, w) orelse "", "-v") and k + 2 < words.len) {
                    if (literalText(a, words[k + 2])) |v| assigned.append(a, v) catch text.outOfMemory();
                }
            }
            continue;
        }
        if (!inList(base, &.{ "rm", "rm.exe", "rmdir", "rmdir.exe", "unlink", "unlink.exe" })) continue;
        var targets: std.ArrayList(Word) = .empty;
        var options_over = false;
        for (words[1..]) |w| {
            const t = literalText(a, w);
            if (!options_over and t != null and std.mem.eql(u8, t.?, "--")) {
                options_over = true;
                continue;
            }
            if (!options_over and t != null and t.?.len > 1 and t.?[0] == '-') continue;
            targets.append(a, w) catch text.outOfMemory();
        }
        out.append(a, .{ .command = c, .targets = targets.items }) catch text.outOfMemory();
    }
    return .{ .list = out.items, .assigned = assigned.items };
}

pub fn changesFolder(a: Allocator, reading: Reading) bool {
    for (reading.commands) |c| {
        for (c.words) |w| {
            const t = literalText(a, w) orelse continue;
            if (inList(t, &.{ "cd", "pushd", "popd" })) return true;
        }
    }
    return false;
}

fn isAssignment(raw: []const u8) bool {
    const eq = std.mem.findScalar(u8, raw, '=') orelse return false;
    var name = raw[0..eq];
    if (name.len > 0 and name[name.len - 1] == '+') name = name[0 .. name.len - 1];
    return isName(name);
}

fn baseName(s: []const u8) []const u8 {
    const i = std.mem.findLastAny(u8, s, "/\\") orelse return s;
    return s[i + 1 ..];
}

fn inList(s: []const u8, list: []const []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, s, item)) return true;
    return false;
}

/// The variables a word reads, in order.
pub fn variables(a: Allocator, w: Word) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (w.parts) |p| switch (p) {
        .variable => |v| out.append(a, v) catch text.outOfMemory(),
        else => {},
    };
    return out.items;
}

pub fn hasOther(w: Word) bool {
    for (w.parts) |p| if (p == .other) return true;
    return false;
}

/// Whether the text names a place without depending on the folder: /x, ~, C:\, C:/, //server.
pub fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '~') return true;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return true;
    return std.mem.startsWith(u8, path, "\\\\");
}

/// `relative` resolved against the folder `cwd`, both in Bash's form, with "." and ".." applied.
pub fn joinPath(a: Allocator, cwd: []const u8, relative: []const u8) []u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, cwd, '/');
    while (it.next()) |s| if (s.len > 0) segments.append(a, s) catch text.outOfMemory();
    var rel = std.mem.splitAny(u8, relative, "/\\");
    while (rel.next()) |s| {
        if (s.len == 0 or std.mem.eql(u8, s, ".")) continue;
        if (std.mem.eql(u8, s, "..")) {
            if (segments.items.len > 0) _ = segments.pop();
            continue;
        }
        segments.append(a, s) catch text.outOfMemory();
    }
    var out: std.ArrayList(u8) = .empty;
    for (segments.items) |s| {
        out.append(a, '/') catch text.outOfMemory();
        out.appendSlice(a, s) catch text.outOfMemory();
    }
    if (out.items.len == 0) out.append(a, '/') catch text.outOfMemory();
    if (relative.len > 0 and (relative[relative.len - 1] == '/' or relative[relative.len - 1] == '\\')) out.append(a, '/') catch text.outOfMemory();
    return out.items;
}

fn testTargets(a: Allocator, source: []const u8) []const []const u8 {
    const reading = read(a, source);
    var out: std.ArrayList([]const u8) = .empty;
    for (deletions(a, reading).list) |d| for (d.targets) |t| out.append(a, t.raw) catch text.outOfMemory();
    return out.items;
}

test "deletion targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expectEqualDeep(@as([]const []const u8, &.{"build"}), testTargets(a, "rm -rf build"));
    try t.expectEqualDeep(@as([]const []const u8, &.{ "a", "-b" }), testTargets(a, "rm -f -- a -b"));
    try t.expectEqualDeep(@as([]const []const u8, &.{"x"}), testTargets(a, "cd /tmp && rm -r x > out.txt 2>&1"));
    try t.expectEqualDeep(@as([]const []const u8, &.{"\"$dir\"/*"}), testTargets(a, "if true; then rm -rf \"$dir\"/*; fi"));
    try t.expectEqualDeep(@as([]const []const u8, &.{}), testTargets(a, "echo 'rm -rf /'"));
    try t.expectEqualDeep(@as([]const []const u8, &.{}), testTargets(a, "cat <<EOF\nrm -rf /\nEOF\necho done"));
    try t.expectEqualDeep(@as([]const []const u8, &.{"y"}), testTargets(a, "cat <<'EOF'\nrm -rf /\nEOF\nrm y"));
    try t.expectEqualDeep(@as([]const []const u8, &.{"z"}), testTargets(a, "# rm -rf /\ncommand rm z"));
    try t.expectEqualDeep(@as([]const []const u8, &.{"/usr/x"}), testTargets(a, "FOO=1 /usr/bin/rm /usr/x"));
}

test "words and parts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reading = read(a, "rm \"$dir\"/x ${HOME}/y $(pwd)/z $1 '$no' a\\ b");
    const d = deletions(a, reading).list[0];
    try std.testing.expectEqualStrings("dir", d.targets[0].parts[0].variable);
    try std.testing.expectEqualStrings("/x", d.targets[0].parts[1].literal);
    try std.testing.expectEqualStrings("HOME", d.targets[1].parts[0].variable);
    try std.testing.expect(hasOther(d.targets[2]));
    try std.testing.expect(hasOther(d.targets[3]));
    try std.testing.expectEqualStrings("$no", literalText(a, d.targets[4]).?);
    try std.testing.expectEqualStrings("a b", literalText(a, d.targets[5]).?);
}

test "assigned names and folders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reading = read(a, "d=/c/x; for f in *; do rm \"$f\"; done; read -r line; cd ..");
    const names = deletions(a, reading).assigned;
    try std.testing.expect(inList("d", names));
    try std.testing.expect(inList("f", names));
    try std.testing.expect(inList("line", names));
    try std.testing.expect(changesFolder(a, reading));
}

test joinPath {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/c/Users/a/build", joinPath(a, "/c/Users/a", "build"));
    try std.testing.expectEqualStrings("/c/Users/build", joinPath(a, "/c/Users/a", "../build"));
    try std.testing.expectEqualStrings("/c/Users/a/*", joinPath(a, "/c/Users/a", "./*"));
}

test "malformed input does not crash the reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "rm ${", "rm $(", "rm \"unclosed", "rm 'unclosed", "rm `x", "cat <<", "rm \\", "${}", "$", "rm ${x" }) |source| {
        _ = deletions(a, read(a, source));
    }
}

test "random input does not crash the reader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alphabet = "${}()'\"\\`<>&|;#\n\t -=*~/0123456789abrmx_";
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buffer: [40]u8 = undefined;
    var round: usize = 0;
    while (round < 50_000) : (round += 1) {
        const len = random.uintLessThan(usize, buffer.len + 1);
        for (buffer[0..len]) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const a = arena.allocator();
        const reading = read(a, buffer[0..len]);
        const dels = deletions(a, reading);
        for (dels.list) |d| for (d.targets) |t| {
            _ = variables(a, t);
            _ = literalText(a, t);
        };
        _ = changesFolder(a, reading);
        _ = arena.reset(.retain_capacity);
    }
}

test {
    std.testing.refAllDecls(@This());
}
