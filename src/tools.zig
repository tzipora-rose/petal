//! What agents see of petal: its tools, their inputs, and the server's instructions. Claude Code
//! cuts any MCP tool description or server instruction at 2,048 characters, so each stays under.

const std = @import("std");

pub const version = "0.1.0";

pub const instructions =
    \\petal runs shell commands in shells that keep their state between calls: PowerShell 7 (pwsh), Windows PowerShell 5.1 (powershell) and Git Bash (bash). Use its run tool for shell commands; shells lists the session's shells; restart starts one fresh.
;

const run_description =
    \\Runs a command in a shell that keeps its state: variables, functions, the folder and environment variables carry over from one call to the next, as in a terminal. Three shells: pwsh (PowerShell 7, the default), powershell (Windows PowerShell 5.1) and bash (Git Bash).
    \\
    \\Each agent has its own set of shells, called a stamen. Pass stamen to use a further set of your own, by a name you choose, for example to run something while a shell of yours is busy; a new stamen starts fresh, or, with from, in another stamen's folder with its environment variables (the shells tool lists the session's stamens).
    \\
    \\Before running, petal checks the command: that it parses, and five traps. In Windows PowerShell 5.1: double quotes inside an argument to a program, and file encodings. In PowerShell: a read of a Claude Code transcript that keeps Claude Code from writing to it, by a .NET reader, Copy-Item or Get-FileHash. In every shell: a deletion whose target is built from a variable, and a deletion by relative path. When it finds something it does not run the command and says what it found: fix the command, or send it again with intended set to true to run it as written.
    \\
    \\The reply has the output (standard output and error together, up to 30,000 characters; when there is more, the reply gives the path of a file holding all of it), the exit code, the time taken and the shell's folder. A command still running at its timeout is ended with everything it started, and so is its shell; the next command starts a fresh one in the same folder. In PowerShell, $LASTEXITCODE starts empty in each command, as in a new PowerShell. A program a command starts ends with its shell.
;

const shells_description =
    \\Lists the session's stamens (each agent's sets of shells) and, for each of their shells, whether it is running, idle or busy (with what, since when), its folder and how many commands it has run. Also gives the folder holding the session's log and each command's full output.
;

const restart_description =
    \\Ends a shell of one of your stamens, with everything it started, and starts it fresh in the folder it was in: its variables, functions and environment changes are gone. Leave shell out to restart every running shell of the stamen. A busy shell is not restarted.
;

pub const list = std.fmt.comptimePrint(
    \\{{"tools":[{{"name":"run","title":"Run a command","description":{f},"inputSchema":{{"type":"object","properties":{{"command":{{"type":"string","description":"The command to run."}},"shell":{{"type":"string","enum":["pwsh","powershell","bash"],"description":"Which shell: pwsh (PowerShell 7, the default), powershell (Windows PowerShell 5.1) or bash (Git Bash)."}},"stamen":{{"type":"string","description":"A further set of shells of your own, by a name you choose: letters, digits, dot, dash and underscore. Leave it out to use your own default set."}},"from":{{"type":"string","description":"When this call starts a shell of a stamen that has not run that shell before, start it in this stamen's folder with its environment variables. A stamen's full name, as the shells tool lists it."}},"timeout":{{"type":"integer","description":"Milliseconds the command may run: default 600000 (10 minutes), at most 14400000 (4 hours)."}},"intended":{{"type":"boolean","description":"Run the command exactly as written although petal's check found something in it."}}}},"required":["command"]}},"annotations":{{"title":"Run a command","readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":true}}}},{{"name":"shells","title":"List shells","description":{f},"inputSchema":{{"type":"object","properties":{{}}}},"annotations":{{"title":"List shells","readOnlyHint":true,"openWorldHint":false}}}},{{"name":"restart","title":"Restart a shell","description":{f},"inputSchema":{{"type":"object","properties":{{"shell":{{"type":"string","enum":["pwsh","powershell","bash"],"description":"The shell to restart; leave it out to restart every running shell of the stamen."}},"stamen":{{"type":"string","description":"Which of your stamens: leave it out for your own default set."}}}}}},"annotations":{{"title":"Restart a shell","readOnlyHint":false,"destructiveHint":true,"idempotentHint":false,"openWorldHint":false}}}}]}}
, .{ std.json.fmt(run_description, .{}), std.json.fmt(shells_description, .{}), std.json.fmt(restart_description, .{}) });

test "descriptions fit Claude Code's cap" {
    try std.testing.expect(run_description.len <= 2048);
    try std.testing.expect(shells_description.len <= 2048);
    try std.testing.expect(restart_description.len <= 2048);
    try std.testing.expect(instructions.len <= 2048);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, list, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("tools").?.array.items.len);
}
