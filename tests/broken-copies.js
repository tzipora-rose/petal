// Deliberately broken copies of petal, each of which petal.test.js must catch. For each one the
// source is copied, one exact piece of it is changed, the copy is built, and the test sections that
// cover that piece run against it: the copy is caught when at least one of their checks fails. The
// first copy changes nothing and must pass every section, or no other result means anything.
//
//   node broken-copies.js [--only <name>...] [--keep]
//
// Needs zig on PATH. Copies are built in Debug, which compiles fastest; the control shows the tests
// pass on such a build. Everything lives in a temp folder removed at exit, unless --keep.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const ONLY = args.includes('--only') ? args.slice(args.indexOf('--only') + 1).filter((a) => !a.startsWith('--')) : null;
const KEEP = args.includes('--keep');

// Each copy: what it breaks, the file and exact text changed, what replaces it, the sections to run.
const COPIES = [
  { name: 'control', breaks: 'nothing: an unchanged copy, which must pass every section', sections: [] },
  { name: 'bash-command-reads-requests', breaks: 'a Bash command gets the request pipe as its standard input', file: 'src/loop.sh', find: 'done </dev/null >"$__petal_out" 2>&1', replace: 'done >"$__petal_out" 2>&1', sections: [4] },
  { name: 'powershell-programs-read-requests', breaks: 'PowerShell\'s standard input is the request pipe, which its programs inherit', file: 'src/shell.zig', find: 'si.StartupInfo.hStdInput = nul;', replace: 'si.StartupInfo.hStdInput = requests.read;', sections: [4] },
  { name: 'no-status-trailer', breaks: 'PowerShell\'s exit code ignores whether the last statement failed', file: 'src/loop.ps1', find: '$block = [ScriptBlock]::Create($request.command + "`n`n__petal_status `$?")', replace: '$block = [ScriptBlock]::Create($request.command)', sections: [5] },
  { name: 'exit-code-carried-over', breaks: '$LASTEXITCODE is not emptied before each command', file: 'src/loop.ps1', find: '$script:SavedExitCode = $global:LASTEXITCODE\n                $global:LASTEXITCODE = $null', replace: '$script:SavedExitCode = $global:LASTEXITCODE', sections: [5] },
  { name: 'break-escapes-the-command', breaks: 'a stray break leaves the command and ends petal\'s loop', file: 'src/loop.ps1', find: '. { do { try { . $__petal_block } catch { __petal_failed; $_ } } while ($false) }', replace: '. { try { . $__petal_block } catch { __petal_failed; $_ } }', sections: [5] },
  { name: 'no-collection-before-reply', breaks: 'a file reader a command left open holds its file after the reply, until a collection the shell may not run for an hour', file: 'src/loop.ps1', find: '        [System.GC]::Collect()\n        [System.GC]::WaitForPendingFinalizers()\n', replace: '', sections: [21] },
  { name: 'no-warning-prefix', breaks: 'warnings lose their WARNING: prefix', file: 'src/loop.ps1', find: "'WARNING: ' + $Item.Message", replace: '$Item.Message', sections: [5] },
  { name: 'no-utf8-console', breaks: 'the console code page is not UTF-8 while a command runs', file: 'src/loop.ps1', find: 'try { [Console]::OutputEncoding = $script:Utf8 } catch {}', replace: '', sections: [6] },
  { name: 'bash-exit-code-lost', breaks: 'Bash reports every command as exit code 0', file: 'src/loop.sh', find: '__petal_status=$?', replace: '__petal_status=0', sections: [2] },
  { name: 'bash-command-in-subshell', breaks: 'each Bash command runs in a subshell, losing its variables and folder', file: 'src/loop.sh', find: 'for __petal_once in 1; do builtin eval "$__petal_command"; done', replace: '( builtin eval "$__petal_command" )', sections: [3] },
  { name: 'powershell-command-in-child-scope', breaks: 'each PowerShell command runs in a scope of its own, losing its variables and functions', file: 'src/loop.ps1', find: 'try { . $__petal_block } catch', replace: 'try { & $__petal_block } catch', sections: [3] },
  { name: 'kill-shell-only', breaks: 'a timeout or cancellation ends the shell but not what it started', file: 'src/shell.zig', find: '_ = win.TerminateJobObject(p.job, 1);', replace: '_ = win.TerminateProcess(p.process, 1);', sections: [11, 12] },
  { name: 'timeout-ignored', breaks: 'a command\'s timeout is not applied', file: 'src/session.zig', find: 'const deadline = t0 + args.timeout_ms;', replace: 'const deadline = t0 + default_timeout_ms;', sections: [11] },
  { name: 'no-busy-check', breaks: 'a call to a busy shell is sent to it anyway', file: 'src/session.zig', find: '    if (sl.busy) {\n        const reply = busyReply(a, st, sl);', replace: '    if (false) {\n        const reply = busyReply(a, st, sl);', sections: [10] },
  { name: 'agent-ignored', breaks: 'every agent gets the main agent\'s shells', file: 'src/session.zig', find: '    if (agent) |name| if (name.len > 0) return name;', replace: '    _ = agent;', sections: [10] },
  { name: 'stamen-name-ignored', breaks: 'a named stamen is the agent\'s default one, so its commands cannot run side by side', file: 'src/session.zig', find: '    };\n    const id = stamenId(a, agent, args.stamen);', replace: '    };\n    const id = stamenId(a, agent, null);', sections: [10] },
  { name: 'from-environment-not-copied', breaks: 'a stamen started from another gets its folder but not its environment', file: 'src/session.zig', find: 'if (copy) |c| if (c.environment) |e| if (sl.kind != .bash) {', replace: 'if (copy) |c| if (c.environment) |e| if (false) {', sections: [10] },
  { name: 'no-truncation', breaks: 'long output comes whole', file: 'src/session.zig', find: 'if (units <= output_limit) return', replace: 'if (true) return', sections: [7] },
  { name: 'no-crlf-cleanup', breaks: 'Windows line endings reach the agent', file: 'src/text.zig', find: "if (crlf and b == '\\r' and i + 1 < bytes.len and bytes[i + 1] == '\\n') {", replace: 'if (crlf and false) {', sections: [6] },
  { name: 'lone-surrogate-rejected', breaks: 'a request holding a lone surrogate is not parsed, so it is never answered by its id', file: 'src/server.zig', find: '    const line = text.pairSurrogates(a, trimmed);', replace: '    const line = trimmed;', sections: [6] },
  { name: 'json-boundary-off', breaks: 'a string that is not valid UTF-8 is written into JSON as it is', file: 'src/output.zig', find: 'if (T == []const u8 or T == []u8) return stringify(a, text.validUtf8(a, value));', replace: 'if (T == []const u8 or T == []u8) return stringify(a, value);', sections: [6] },
  { name: 'markers-left-in-output', breaks: 'the loops\' markers show up as output a program wrote', file: 'src/shell.zig', find: '            i = z + nl + 1;\n            from = i;', replace: '            i = z + nl + 1;\n            from = z;', sections: [8] },
  { name: 'cancel-ignored', breaks: 'a cancellation does not stop the call\'s command', file: 'src/server.zig', find: '_ = win.SetEvent(c.cancel);', replace: '_ = c.cancel;', sections: [12] },
  { name: 'no-progress', breaks: 'no progress is sent during a long command', file: 'src/server.zig', find: '    call.server.out.notify(a, "notifications/progress",', replace: '    if (false) call.server.out.notify(a, "notifications/progress",', sections: [13] },
  { name: 'no-inbox', breaks: 'waiting messages are never delivered', file: 'src/server.zig', find: 'for (inbox.take(a, server.session.inbox)) |m| {', replace: 'for (@as([]const inbox.Message, &.{})) |m| {', sections: [14] },
  { name: 'inbox-newest-first', breaks: 'messages come newest name first', file: 'src/inbox.zig', find: 'return std.mem.order(u8, x, y) == .lt;', replace: 'return std.mem.order(u8, x, y) == .gt;', sections: [14] },
  { name: 'hook-writes-no-agent', breaks: 'the hook leaves the calling agent out of the call', file: 'src/hook.zig', find: 'tool_input.put(a, "agent", .{ .string = agent }) catch return null;', replace: 'if (false) tool_input.put(a, "agent", .{ .string = agent }) catch return null;', sections: [16] },
  { name: 'pwd-kept', breaks: 'a shell inherits petal\'s PWD', file: 'src/session.zig', find: '        removeFolderVariables(&env);\n        env.set("POWERSHELL_TELEMETRY_OPTOUT", "1");\n        if (paths.claudeExecutable(a)) |claude|', replace: '        env.set("POWERSHELL_TELEMETRY_OPTOUT", "1");\n        if (paths.claudeExecutable(a)) |claude|', sections: [17] },
  { name: 'telemetry-not-off', breaks: 'POWERSHELL_TELEMETRY_OPTOUT is not set for the shells', file: 'src/session.zig', find: '        env.set("POWERSHELL_TELEMETRY_OPTOUT", "1");\n        if (paths.claudeExecutable(a)) |claude|', replace: '        if (paths.claudeExecutable(a)) |claude|', sections: [17] },
  { name: 'execpath-parent-ignored', breaks: 'petal looks for Claude Code only through CLAUDE_PID, which Claude Code does not give its MCP servers', file: 'src/paths.zig', find: 'if (entry.th32ProcessID == self) return entry.th32ParentProcessID;', replace: 'if (entry.th32ProcessID == self) return null;', sections: [17] },
  { name: 'no-execpath', breaks: 'CLAUDE_CODE_EXECPATH is not set for the shells', file: 'src/session.zig', find: 'if (paths.claudeExecutable(a)) |claude| env.set("CLAUDE_CODE_EXECPATH", claude);', replace: '_ = paths.claudeExecutable(a);', sections: [17] },
  { name: 'powershell-loop-variables-kept', breaks: 'PowerShell commands see PETAL_LOOP, PETAL_IN and PETAL_OUT', file: 'src/loop.ps1', find: 'Microsoft.PowerShell.Management\\Remove-Item -Path Env:PETAL_LOOP, Env:PETAL_IN, Env:PETAL_OUT', replace: '', sections: [17] },
  { name: 'bash-loop-variable-kept', breaks: 'Bash commands see PETAL_LOOP', file: 'src/loop.sh', find: 'unset PETAL_LOOP\nchcp.com', replace: 'chcp.com', sections: [17] },
  { name: 'no-idle-sweep', breaks: 'an idle stamen\'s shells never end', file: 'src/session.zig', find: 'if (now -| st.last_used < s.idle_limit_ms) continue;', replace: 'if (now -| st.last_used < s.idle_limit_ms or true) continue;', sections: [18] },
  { name: 'data-in-localappdata', breaks: 'petal keeps its data under %LOCALAPPDATA%, which the app\'s package hides from programs outside it', file: 'src/paths.zig', find: 'const profile = getEnv(a, "USERPROFILE") orelse return null;\n    return join(a, &.{ profile, ".petal" });', replace: 'const profile = getEnv(a, "LOCALAPPDATA") orelse return null;\n    return join(a, &.{ profile, "petal" });', sections: [19] },
  { name: 'call-memory-kept', breaks: 'a call\'s memory is never freed', file: 'src/server.zig', find: '    call.arena.deinit();\n    lasting.destroy(call);', replace: '    lasting.destroy(call);', sections: [20] },
  { name: 'version-not-negotiated', breaks: 'initialize always answers with the newest protocol version', file: 'src/server.zig', find: 'version = known;', replace: 'version = protocol_versions[0];', sections: [1] },
  { name: 'run-read-only', breaks: 'run is marked read-only, so Claude Code would send one agent\'s runs at once', file: 'src/tools.zig', find: '"annotations":{{"title":"Run a command","readOnlyHint":false', replace: '"annotations":{{"title":"Run a command","readOnlyHint":true', sections: [1] },
  { name: 'check: parse errors', breaks: 'PowerShell commands that do not parse are sent to run', file: 'src/loop.ps1', find: '        if ($errors.Count -gt 0) {\n            $result.errors', replace: '        if ($false) {\n            $result.errors', sections: [9] },
  { name: 'check: relative deletion', breaks: 'a PowerShell deletion by relative path is not stopped', file: 'src/loop.ps1', find: 'if ($null -ne $resolved.Text -and (IsRelative $resolved.Text)) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: deletion through a variable', breaks: 'a PowerShell deletion whose target is built from a variable is not stopped', file: 'src/loop.ps1', find: '        if ($variables.Count -gt 0) {', replace: '        if ($false) {', sections: [9] },
  { name: 'check: names the command sets', breaks: 'a variable the command sets itself is read as if its value were known', file: 'src/loop.ps1', find: 'Assigned = AssignedNames $ast', replace: 'Assigned = [System.Collections.Generic.HashSet[string]]::new()', sections: [9] },
  { name: 'check: encoding', breaks: 'Windows PowerShell 5.1\'s Out-File without -Encoding is not stopped', file: 'src/loop.ps1', find: "$writes = $true; EncodingFinding $c 'Out-File' 'UTF-16' $context", replace: '$writes = $true', sections: [9] },
  { name: 'check: read-then-write', breaks: 'Windows PowerShell 5.1\'s Get-Content then write back is not stopped', file: 'src/loop.ps1', find: 'foreach ($read in $plainReads) {', replace: 'foreach ($read in @()) {', sections: [9] },
  { name: 'check: quotes', breaks: 'double quotes in an argument to a program are not stopped in 5.1', file: 'src/loop.ps1', find: 'if ($script:IsWindowsPowerShell) { QuoteFindings $c $resolved.Name $context }', replace: '', sections: [9] },
  { name: 'check: bash syntax', breaks: 'Bash commands that do not parse are sent to run', file: 'src/session.zig', find: 'if (syntaxProblem(s, a, command)) |problem| {', replace: 'if (@as(?[]const u8, null)) |problem| {', sections: [9] },
  { name: 'check: bash rm', breaks: 'Bash\'s rm is not recognized as a deletion', file: 'src/bashcheck.zig', find: '&.{ "rm", "rm.exe", "rmdir", "rmdir.exe", "unlink", "unlink.exe" }', replace: '&.{ "rmdir", "rmdir.exe", "unlink", "unlink.exe" }', sections: [9] },
  { name: 'check: bash deletion through a variable', breaks: 'a Bash deletion whose target is built from a variable is not stopped', file: 'src/session.zig', find: 'if (vars.len > 0 or bashcheck.hasOther(t)) {', replace: 'if (false) {', sections: [9] },
  { name: 'check: transcript read', breaks: 'a PowerShell read of a Claude Code transcript that blocks its writes is not stopped', file: 'src/loop.ps1', find: 'if ($null -eq $reader -or -not $reader.Holds) { return }', replace: 'return', sections: [9] },
  { name: 'check: transcript share argument', breaks: 'a reader whose share argument allows writing is stopped as if it did not', file: 'src/loop.ps1', find: 'return ($share -band [int][System.IO.FileShare]::Write) -eq 0', replace: 'return $true', sections: [9] },
  { name: 'check: transcripts from CLAUDE_CONFIG_DIR', breaks: 'the transcripts are looked for under .claude in the home folder even when CLAUDE_CONFIG_DIR names another', file: 'src/loop.ps1', find: '$config = [System.Environment]::GetEnvironmentVariable(\'CLAUDE_CONFIG_DIR\')', replace: '$config = $null', sections: [9] },
  { name: 'check: transcripts from USERPROFILE', breaks: 'without CLAUDE_CONFIG_DIR, the home folder is not the USERPROFILE Claude Code uses', file: 'src/loop.ps1', find: '$profileFolder = [System.Environment]::GetEnvironmentVariable(\'USERPROFILE\')', replace: '$profileFolder = $null', sections: [9] },
  { name: 'check: transcript switch -File', breaks: 'switch -File on a transcript is not stopped', file: 'src/loop.ps1', find: 'if (($s.Flags -band [System.Management.Automation.Language.SwitchFlags]::File) -eq 0) { continue }', replace: 'continue', sections: [9] },
  { name: 'check: transcript New-Object', breaks: 'New-Object IO.StreamReader or IO.FileStream on a transcript is not stopped', file: 'src/loop.ps1', find: '\'New-Object\' { ReaderFinding $c (NewObjectReader $c) $context }', replace: '\'New-Object\' { }', sections: [9] },
  { name: 'check: transcript path the command sets', breaks: 'a transcript path the command puts in a variable before reading it is not named', file: 'src/loop.ps1', find: 'return StatementExpression $found.Right', replace: 'return $null', sections: [9] },
  { name: 'check: transcript named as .jsonl', breaks: 'a reader of a file found as the command runs is not stopped when the command names .jsonl', file: 'src/loop.ps1', find: 'if ($context.Text -match \'(?<!\\\\)\\.jsonl\') { return \'a .jsonl file\' }', replace: 'if ($false) { return \'a .jsonl file\' }', sections: [9] },
  { name: 'check: .jsonl as regex text', breaks: 'a .jsonl written as regex text counts as naming a .jsonl file', file: 'src/loop.ps1', find: 'if ($context.Text -match \'(?<!\\\\)\\.jsonl\') { return \'a .jsonl file\' }', replace: 'if ($context.Text -match \'\\.jsonl\') { return \'a .jsonl file\' }', sections: [9] },
  { name: 'check: transcript other extension', breaks: 'a path whose fixed end names another extension counts as possibly a transcript', file: 'src/loop.ps1', find: 'return $m.Success -and $m.Groups[1].Value -ne \'jsonl\'', replace: 'return $false', sections: [9] },
  { name: 'check: transcript folder named', breaks: 'a reader of a file found as the command runs is not stopped when the command names the transcripts\' folder', file: 'src/loop.ps1', find: 'if ($context.Transcripts) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: Copy-Item read', breaks: 'Copy-Item of a transcript is not stopped', file: 'src/loop.ps1', find: '\'Copy-Item\' { CmdletReaderFindings $c \'Copy-Item\' $context }', replace: '\'Copy-Item\' { }', sections: [9] },
  { name: 'check: Get-FileHash read', breaks: 'Get-FileHash of a transcript is not stopped', file: 'src/loop.ps1', find: '\'Get-FileHash\' { CmdletReaderFindings $c \'Get-FileHash\' $context }', replace: '\'Get-FileHash\' { }', sections: [9] },
  { name: 'check: Copy-Item -Recurse', breaks: 'Copy-Item -Recurse of a folder holding transcripts is not stopped', file: 'src/loop.ps1', find: 'if ($recurse -and (HoldsTranscripts $full $context.Transcripts)) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: -Path wildcards', breaks: 'a -Path wildcard is taken as a file name instead of matched', file: 'src/loop.ps1', find: 'if ($wildcards -and [System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($text)) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: loop variables', breaks: 'a foreach loop\'s variable is not read from the list the loop runs over', file: 'src/loop.ps1', find: '            if ($null -ne $loop) { return $loop }\n', replace: '', sections: [9] },
  { name: 'check: lists', breaks: 'a list of paths is not read', file: 'src/loop.ps1', find: 'if ($node -is [System.Management.Automation.Language.ArrayLiteralAst] -or $node -is [System.Management.Automation.Language.ArrayExpressionAst]) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: a list the shell holds', breaks: 'a list of paths held in a variable is not read', file: 'src/loop.ps1', find: 'if ($value -is [System.Collections.IList] -and $value.Count -gt 0 -and $value.Count -le 64) {', replace: 'if ($false) {', sections: [9] },
  { name: 'check: -InputStream left to its stream', breaks: 'Get-FileHash -InputStream is checked as if it named a file', file: 'src/loop.ps1', find: 'if ($cmdlet -eq \'Get-FileHash\' -and $null -ne (BoundAst $commandAst \'InputStream\')) { return }', replace: '', sections: [9] },
  { name: 'check: a .md path is no clue', breaks: 'a path into the transcripts\' folder naming a .md file counts as naming the folder', file: 'src/loop.ps1', find: 'if (-not (OtherExtension $m.Groups[1].Value)) {', replace: 'if ($true) {', sections: [9] },
];

const failures = [];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'petal-broken-'));
process.on('exit', () => {
  if (KEEP) { console.log('kept: ' + tmp); return; }
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (e) { console.log('could not remove ' + tmp + ': ' + e.message); }
});

// Every change must find its text exactly once, in the file's own line endings, before anything is
// built: a change whose text has moved on would test nothing and still look caught.
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');
const inFileEndings = (content, s) => (content.includes('\r\n') ? s.replace(/\n/g, '\r\n') : s);
const count = (hay, needle) => (needle === '' ? 0 : hay.split(needle).length - 1);
const chosen = COPIES.filter((c) => !ONLY || ONLY.includes(c.name));
const unknown = (ONLY || []).filter((n) => !COPIES.some((c) => c.name === n));
if (unknown.length > 0) { console.log('No copy is named: ' + unknown.join(', ')); process.exit(2); }
let stale = 0;
for (const c of chosen) {
  if (!c.file) continue;
  const content = read(c.file);
  const n = count(content, inFileEndings(content, c.find));
  if (n !== 1) { console.log(`STALE: ${c.name}: its text occurs ${n} times in ${c.file}`); stale++; }
}
if (stale > 0) { console.log(stale + ' change(s) no longer match the source; fix them before running.'); process.exit(2); }

function copySource(to) {
  fs.mkdirSync(to, { recursive: true });
  fs.copyFileSync(path.join(ROOT, 'build.zig'), path.join(to, 'build.zig'));
  fs.cpSync(path.join(ROOT, 'src'), path.join(to, 'src'), { recursive: true });
}

console.log(`${chosen.length} copies, built in ${tmp}\n`);
for (const c of chosen) {
  const dir = path.join(tmp, c.name.replace(/[^A-Za-z0-9-]+/g, '_'));
  copySource(dir);
  if (c.file) {
    const target = path.join(dir, c.file);
    const content = fs.readFileSync(target, 'utf8');
    fs.writeFileSync(target, content.replace(inFileEndings(content, c.find), () => inFileEndings(content, c.replace)));
  }
  const built = spawnSync('zig', ['build'], { cwd: dir, encoding: 'utf8', windowsHide: true });
  const exe = path.join(dir, 'zig-out', 'bin', 'petal.exe');
  if (built.status !== 0 || !fs.existsSync(exe)) {
    console.log(`${c.name.padEnd(40)} DID NOT BUILD: ${(built.stderr || '').split('\n').slice(0, 4).join(' | ')}`);
    failures.push(c.name + ' (did not build)');
    continue;
  }
  const only = c.sections.length > 0 ? ['--only', ...c.sections.map(String)] : [];
  const t0 = Date.now();
  const ran = spawnSync(process.execPath, [path.join(__dirname, 'petal.test.js'), '--petal', exe, ...only], { encoding: 'utf8', windowsHide: true, maxBuffer: 64 * 1024 * 1024 });
  const failed = (ran.stdout || '').split('\n').filter((l) => / FAIL( |$)/.test(l)).map((l) => l.trim().replace(/\s{2,}/g, ' '));
  const seconds = ((Date.now() - t0) / 1000).toFixed(0) + ' s';
  if (c.name === 'control') {
    const ok = ran.status === 0 && failed.length === 0;
    console.log(`${c.name.padEnd(40)} ${ok ? 'passes every section' : 'FAILS: ' + (failed[0] || 'exit ' + ran.status)} (${seconds})`);
    if (!ok) failures.push('control');
    continue;
  }
  const caught = ran.status === 1 && failed.length > 0;
  console.log(`${c.name.padEnd(40)} ${caught ? 'caught' : 'NOT CAUGHT'}: ${c.breaks} (sections ${c.sections.join(', ')}, ${failed.length} failing, ${seconds})`);
  if (caught) console.log('    first failing check: ' + failed[0].slice(0, 160));
  else failures.push(c.name);
}
const ranControl = chosen.some((c) => c.name === 'control');
const caughtLine = ranControl ? 'Every broken copy was caught, and the control passed.' : 'Every broken copy run was caught; the control was not run.';
console.log('\n' + (failures.length === 0 ? caughtLine : 'NOT AS EXPECTED: ' + failures.join(', ')));
process.exitCode = failures.length === 0 ? 0 : 1;
