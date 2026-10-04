// Verifies petal over its own protocol, against running the same commands in the shells directly:
// output and exit codes must match a fresh run; variables, functions, folder and environment must
// carry over; a command's programs must never read petal's requests; the check must stop exactly
// what it should; timeouts and cancellations must end everything a command started; each agent must
// have its own shells; messages must arrive once; memory must not grow with use; a file a command
// left open must be free for other programs to write by the time petal replies.
//
//   node petal.test.js [--petal <petal.exe>] [--only <section number>...]
//
// petal defaults to ..\zig-out\bin\petal.exe, which `zig build --release` writes. Everything the
// test makes (petal's data, files the commands touch) lives in a temp folder it removes at exit.
// Every deletion a test sends targets that folder too: broken-copies.js runs these tests against
// copies of petal whose check is broken, so whatever the check should stop does run there.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync, execFileSync } = require('child_process');

const args = process.argv.slice(2);
const argOf = (k) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : null; };
const PETAL = path.resolve(argOf('--petal') || path.join(__dirname, '..', 'zig-out', 'bin', 'petal.exe'));
const ONLY = args.includes('--only') ? args.slice(args.indexOf('--only') + 1).map(Number) : null;
if (!fs.existsSync(PETAL)) {
  console.log('No petal at ' + PETAL + '. Build it first, in the petal folder: zig build --release');
  process.exit(2);
}
const NODE = process.execPath;
const CHILD = path.join(__dirname, 'child.js');
const fwd = (p) => p.split('\\').join('/');

let checks = 0;
let failures = 0;
const failed = [];
const check = (label, cond, detail) => {
  checks++;
  console.log('   ' + label.padEnd(100) + ' ' + (cond ? 'PASS' : 'FAIL ' + (detail === undefined ? '' : String(detail).slice(0, 600))));
  if (!cond) { failures++; failed.push(label); }
};
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const waitFor = async (cond, ms) => { const end = Date.now() + ms; while (Date.now() < end) { if (await cond()) return true; await sleep(50); } return cond(); };
const hex = (s) => Buffer.from(s, 'utf8').toString('hex');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'petal-test-'));
const WORK = path.join(tmp, 'work');
fs.mkdirSync(WORK);
const petals = new Set();
process.on('exit', () => {
  for (const p of petals) { try { p.proc.kill(); } catch (e) { /* already gone */ } }
  const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  for (let attempt = 1; ; attempt++) {
    try { fs.rmSync(tmp, { recursive: true, force: true }); break; } catch (e) {
      if (attempt === 50) { console.log('could not remove ' + tmp + ': ' + e.message); break; }
      pause(200);
    }
  }
});

// petal's environment holds nothing of what it must set or remove itself, so a check of the shells'
// environment sees petal's work and not the account's own settings.
const baseEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(PETAL_.*|CLAUDE_CODE_SESSION_ID|CLAUDE_PID|CLAUDE_CODE_EXECPATH|POWERSHELL_TELEMETRY_OPTOUT|PWD|OLDPWD)$/i.test(k)));

let instances = 0;
class Petal {
  // `launch`, when given, is the program that starts petal in its place: { command, args }.
  constructor(extraEnv = {}, launch = null) {
    this.n = ++instances;
    this.dataDir = path.join(tmp, 'data-' + this.n);
    this.sessionId = 'test-' + this.n;
    this.sessionDir = path.join(this.dataDir, 'sessions', this.sessionId);
    // A variable given as null in extraEnv is removed from petal's environment.
    const env = { ...baseEnv, PETAL_DATA_DIR: this.dataDir, CLAUDE_CODE_SESSION_ID: this.sessionId, ...extraEnv };
    for (const k of Object.keys(env)) if (env[k] === null) delete env[k];
    this.proc = spawn(launch ? launch.command : PETAL, launch ? launch.args : [], { stdio: ['pipe', 'pipe', 'pipe'], cwd: WORK, windowsHide: true, env });
    petals.add(this);
    this.buf = '';
    this.waiters = new Map();
    this.notifications = [];
    this.bad = [];
    this.nextId = 1;
    this.stderr = '';
    // A petal that has exited answers nothing more: its pending requests resolve empty at once, so
    // none of their timers keeps this process running, and writing to it is not an error.
    this.hasExited = false;
    this.exited = new Promise((r) => this.proc.on('exit', (code) => {
      this.hasExited = true;
      petals.delete(this);
      for (const w of this.waiters.values()) w(null);
      this.waiters.clear();
      r(code);
    }));
    this.proc.stdin.on('error', () => {});
    this.proc.stderr.on('data', (d) => { this.stderr += d; });
    this.proc.stdout.on('data', (d) => {
      this.buf += d.toString('utf8');
      let nl;
      while ((nl = this.buf.indexOf('\n')) >= 0) {
        const line = this.buf.slice(0, nl);
        this.buf = this.buf.slice(nl + 1);
        let msg;
        try { msg = JSON.parse(line); } catch (e) { this.bad.push(line); continue; }
        if (msg.id !== undefined && msg.id !== null && this.waiters.has(JSON.stringify(msg.id))) {
          const w = this.waiters.get(JSON.stringify(msg.id));
          this.waiters.delete(JSON.stringify(msg.id));
          w(msg);
        } else this.notifications.push(msg);
      }
    });
  }
  send(obj) { this.proc.stdin.write(JSON.stringify(obj) + '\n'); }
  request(method, params, { id, timeout = 120000 } = {}) {
    const rid = id === undefined ? this.nextId++ : id;
    if (this.hasExited) return Promise.resolve(null);
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.waiters.delete(JSON.stringify(rid)); resolve(null); }, timeout);
      this.waiters.set(JSON.stringify(rid), (m) => { clearTimeout(timer); resolve(m); });
      this.send({ jsonrpc: '2.0', id: rid, method, params });
    });
  }
  async init() {
    const r = await this.request('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'petal-test', version: '0' } });
    this.send({ jsonrpc: '2.0', method: 'notifications/initialized' });
    return r;
  }
  async tool(name, args, opts = {}) {
    const params = { name, arguments: args };
    if (opts.token !== undefined) params._meta = { progressToken: opts.token };
    const m = await this.request('tools/call', params, opts);
    if (!m) return { text: null, isError: null, msg: null };
    if (m.error) return { text: null, isError: null, error: m.error, msg: m };
    const t = m.result && m.result.content && m.result.content[0] ? m.result.content[0].text : undefined;
    if (typeof t !== 'string') {
      check('every reply\'s text is a string', false, JSON.stringify(m).slice(0, 300));
      return { text: JSON.stringify(t), isError: m.result && m.result.isError, msg: m };
    }
    return { text: t, isError: m.result.isError, msg: m };
  }
  run(args, opts) { return this.tool('run', { agent: 'main', ...args }, opts); }
  async close() {
    this.proc.stdin.end();
    let timer;
    const limit = new Promise((r) => { timer = setTimeout(() => r('timeout'), 15000); });
    const code = await Promise.race([this.exited, limit]);
    clearTimeout(timer);
    return code;
  }
}
const outputOf = (t) => (t || '').split('\n— ')[0];
const exitOf = (t) => { const m = /\n— exit code (-?\d+),/.exec(t || ''); return m ? Number(m[1]) : null; };

const SHELLS = {
  pwsh: spawnSync('where.exe', ['pwsh.exe'], { encoding: 'utf8' }).stdout.split(/\r?\n/)[0],
  powershell: path.join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
  bash: path.join(process.env.ProgramFiles, 'Git', 'bin', 'bash.exe'),
};
// The same command run directly in a fresh shell, its output and errors merged in the order they
// were written. PowerShell compiles the command as a script block of its own, as petal does, so an
// error names the same line and column; the exit code is the one Claude Code's PowerShell tool
// reports ($LASTEXITCODE when a program ran, else 0 or 1 from $?). Both shells switch their console
// to UTF-8 first, as petal's do, and PowerShell 7 renders plain text, as it does inside petal,
// instead of coloring errors and warnings for a console. The script goes in on standard input:
// Windows PowerShell 5.1 given -EncodedCommand writes its errors and warnings as XML.
function direct(shell, command, cwd = WORK) {
  let r;
  if (shell === 'bash') {
    r = spawnSync(SHELLS.bash, ['--noprofile', '--norc', '-c', 'chcp.com 65001 >/dev/null 2>&1\n{ ' + command + '\n} </dev/null 2>&1'], { cwd, encoding: 'utf8', windowsHide: true, env: baseEnv });
  } else {
    const script = [
      '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [System.Text.UTF8Encoding]::new($false)',
      "if ($PSVersionTable.PSVersion.Major -ge 7) { $PSStyle.OutputRendering = 'PlainText' }",
      ". ([ScriptBlock]::Create($env:PETAL_TEST_COMMAND + \"`n`n\" + '$global:__petal_test_ok = $?'))",
      '$__ec = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($global:__petal_test_ok) { 0 } else { 1 }; exit $__ec',
    ].join('\n') + '\n';
    const line = `"${SHELLS[shell]}" -NoLogo -NoProfile -NonInteractive -OutputFormat Text -Command - 2>&1`;
    r = spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', `"${line}"`], { cwd, input: script, encoding: 'utf8', windowsHide: true, windowsVerbatimArguments: true, env: { ...baseEnv, PETAL_TEST_COMMAND: command } });
  }
  return { out: r.stdout || '', code: r.status };
}
const norm = (s) => (s || '').replace(/\r\n/g, '\n').split('\n').map((l) => l.replace(/ +$/, '')).join('\n').replace(/\n+$/, '');
const section = (n, title) => { if (ONLY && !ONLY.includes(n)) return false; console.log('\n' + n + '. ' + title); return true; };

// Failure until the last line says otherwise: a run that stops early never counts as passing.
process.exitCode = 1;
process.on('uncaughtException', (e) => {
  check('the test itself ran to its end', false, 'it stopped with ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e));
  for (const p of petals) { try { p.proc.kill(); } catch (err) { /* already gone */ } }
});

(async () => {
  console.log('petal: ' + PETAL);
  console.log('work folder: ' + WORK);

  // ---- 1 -------------------------------------------------------------------------------------------
  if (section(1, 'the protocol')) {
    const p = new Petal();
    const init = await p.init();
    check('initialize answers with the version asked for, when petal knows it', init && init.result.protocolVersion === '2025-11-25', JSON.stringify(init));
    check('initialize names the server petal and declares tools', init && init.result.serverInfo.name === 'petal' && init.result.capabilities.tools, JSON.stringify(init && init.result));
    const old = await p.request('initialize', { protocolVersion: '2024-11-05', capabilities: {} });
    check('an older version petal knows is answered in kind', old && old.result.protocolVersion === '2024-11-05', JSON.stringify(old));
    const future = await p.request('initialize', { protocolVersion: '2099-01-01', capabilities: {} });
    check('an unknown version is answered with the newest petal knows', future && future.result.protocolVersion === '2025-11-25', JSON.stringify(future));
    const list = await p.request('tools/list', {});
    const tools = list && list.result.tools;
    check('tools/list has run, shells and restart', tools && tools.map((t) => t.name).join(',') === 'run,shells,restart', JSON.stringify(tools && tools.map((t) => t.name)));
    check('every description and the instructions fit Claude Code\'s 2,048-character cap', tools && tools.every((t) => t.description.length <= 2048) && init.result.instructions.length <= 2048);
    check('run requires a command; shells is marked read-only', tools && JSON.stringify(tools[0].inputSchema.required) === '["command"]' && tools[1].annotations.readOnlyHint === true);
    check('run and restart are not marked read-only, so Claude Code never sends one agent\'s two runs at once', tools && tools[0].annotations.readOnlyHint === false && tools[2].annotations.readOnlyHint === false);
    const ping = await p.request('ping', {});
    check('ping answers {}', ping && JSON.stringify(ping.result) === '{}', JSON.stringify(ping));
    const unknown = await p.request('resources/list', {});
    check('an unknown method is answered "method not found" (-32601)', unknown && unknown.error && unknown.error.code === -32601, JSON.stringify(unknown));
    const badTool = await p.request('tools/call', { name: 'nope', arguments: {} });
    check('an unknown tool is answered -32602', badTool && badTool.error && badTool.error.code === -32602, JSON.stringify(badTool));
    const stringId = await p.request('ping', {}, { id: 'an id' });
    check('a string id comes back exactly', stringId && stringId.id === 'an id', JSON.stringify(stringId));
    p.proc.stdin.write('this is not json\n');
    p.proc.stdin.write('[{"jsonrpc":"2.0","id":99,"method":"ping"}]\n');
    await waitFor(() => p.notifications.filter((m) => m.error).length >= 2, 5000);
    const errors = p.notifications.filter((m) => m.error).map((m) => m.error.code);
    check('a line that is not JSON gets -32700, a batch gets -32600', errors.includes(-32700) && errors.includes(-32600), JSON.stringify(errors));
    const before = p.notifications.length;
    p.send({ jsonrpc: '2.0', method: 'notifications/whatever', params: {} });
    await sleep(500);
    check('a notification gets no answer', p.notifications.length === before);
    const noCommand = await p.tool('run', { agent: 'main' });
    check('run without a command is refused, nothing run', noCommand.isError === true && /"command" is missing/.test(noCommand.text), noCommand.text);
    const badShell = await p.run({ shell: 'cmd', command: 'dir' });
    check('an unknown shell is refused and the three shells named', badShell.isError === true && /pwsh .*powershell .*bash/.test(badShell.text), badShell.text);
    check('nothing petal wrote to its standard output was anything but JSON', p.bad.length === 0, p.bad.join(' | '));
    await p.close();
  }

  // ---- 2 -------------------------------------------------------------------------------------------
  if (section(2, 'output and exit codes match a direct run of the same command')) {
    const p = new Petal();
    await p.init();
    const cases = {
      pwsh: [
        "'é中😀 ✓ ' + [char]0x2603",
        '1..5 | ForEach-Object { $_ * $_ }',
        "\"tab`there\"; ''; 'after an empty line'",
        `& '${NODE}' '${CHILD}' print '${hex('from a program: é中😀\n')}'`,
        `& '${NODE}' '${CHILD}' exit 7`,
        'Get-Item C:\\petal-test-no-such-path; "after"',
        "Write-Warning 'w'; Write-Verbose 'v' -Verbose; 'out'",
        "throw 'stopped here'",
        'cmd /c echo é',
        'Get-ChildItem $env:SystemRoot\\System32\\drivers\\etc | Select-Object -First 2 Name, Length',
      ],
      bash: [
        "printf 'é中😀 ✓\\n'",
        'echo a; echo b >&2; echo c',
        `"${fwd(NODE)}" "${fwd(CHILD)}" print ${hex('from a program: é中😀\n')}`,
        `"${fwd(NODE)}" "${fwd(CHILD)}" exit 7`,
        'ls /petal-test-no-such-path',
        'false',
        'cmd //c echo é',
      ],
    };
    cases.powershell = cases.pwsh.slice();
    for (const shell of ['pwsh', 'powershell']) {
      const d = direct(shell, 'Get-Item C:\\petal-test-no-such-path; "after"');
      check(shell + ': control: run directly, an error and the output after it both print, as plain text', /Cannot find path[^\n]*\n[\s\S]*after/.test(d.out) && !/\u001b|CLIXML/.test(d.out), JSON.stringify(d.out));
    }
    for (const shell of ['pwsh', 'powershell', 'bash']) {
      for (const command of cases[shell]) {
        const d = direct(shell, command);
        const r = await p.run({ shell, command, intended: true });
        const label = shell + ': `' + command.replace(/\n/g, ' ').slice(0, 70) + '`';
        check(label + ' exit code ' + d.code, exitOf(r.text) === d.code, 'petal ' + exitOf(r.text) + ' direct ' + d.code);
        const same = norm(outputOf(r.text)) === norm(d.out) || (norm(d.out) === '' && outputOf(r.text) === '(no output)');
        check(label + ' output', same, 'petal ' + JSON.stringify(norm(outputOf(r.text))) + ' direct ' + JSON.stringify(norm(d.out)));
      }
    }
    await p.close();
  }

  // ---- 3 -------------------------------------------------------------------------------------------
  if (section(3, 'variables, functions, the folder and environment variables carry over')) {
    const p = new Petal();
    await p.init();
    const sub = path.join(WORK, 'carry');
    fs.mkdirSync(sub, { recursive: true });
    for (const shell of ['pwsh', 'powershell']) {
      await p.run({ shell, command: `$kept = 41; function Grow { $global:kept++; $global:kept }; Set-Location '${sub}'; $env:PETAL_TEST_CARRY = 'é'` });
      const r = await p.run({ shell, command: 'Grow; (Get-Location).Path; $env:PETAL_TEST_CARRY' });
      check(shell + ': a variable, a function, the folder and an environment variable all carry over', norm(outputOf(r.text)) === ['42', sub, 'é'].join('\n'), outputOf(r.text));
    }
    await p.run({ shell: 'bash', command: `kept=41; grow() { kept=$((kept+1)); echo $kept; }; cd "${fwd(sub)}"; export PETAL_TEST_CARRY=é` });
    const b = await p.run({ shell: 'bash', command: 'grow; pwd -W; echo "$PETAL_TEST_CARRY"' });
    check('bash: a variable, a function, the folder and an environment variable all carry over', norm(outputOf(b.text)) === ['42', fwd(sub), 'é'].join('\n'), outputOf(b.text));
    const control = direct('pwsh', '$kept');
    check('control: a fresh PowerShell knows none of it', norm(control.out) === '', control.out);
    await p.close();
  }

  // ---- 4 -------------------------------------------------------------------------------------------
  if (section(4, 'a program a command starts reads nothing of petal\'s requests')) {
    const p = new Petal();
    await p.init();
    for (const shell of ['pwsh', 'powershell', 'bash']) {
      const cmd = shell === 'bash' ? `"${fwd(NODE)}" "${fwd(CHILD)}" stdin` : `& '${NODE}' '${CHILD}' stdin`;
      const r = await p.run({ shell, command: cmd });
      check(shell + ': a program reading its standard input gets its end at once, and nothing', /stdin ended after 0 bytes/.test(r.text || ''), r.text);
      const after = await p.run({ shell, command: shell === 'bash' ? 'echo next' : "'next'" });
      check(shell + ': the next command still runs', norm(outputOf(after.text)) === 'next', after.text);
    }
    const ctl = spawnSync(SHELLS.pwsh, ['-NoProfile', '-NonInteractive', '-Command', `& '${NODE}' '${CHILD}' stdin`], { input: 'petal-request-bytes\n', encoding: 'utf8', windowsHide: true });
    check('control: run from a PowerShell whose input is a pipe, the program reads what is in it', /stdin ended after 20 bytes/.test(ctl.stdout), ctl.stdout);
    const bashRead = await p.run({ shell: 'bash', command: 'read -r line; echo "read gave $? [$line]"; cat; echo "cat gave $?"', timeout: 15000 });
    check('bash: read and cat get the end of input', norm(outputOf(bashRead.text)) === 'read gave 1 []\ncat gave 0', bashRead.text);
    await p.close();
  }

  // ---- 5 -------------------------------------------------------------------------------------------
  if (section(5, 'exit codes, errors and the loop\'s own safety')) {
    const p = new Petal();
    await p.init();
    for (const shell of ['pwsh', 'powershell']) {
      const nonTerminating = await p.run({ shell, command: 'Get-Item C:\\petal-test-no-such-path' });
      check(shell + ': a command whose last statement failed reports exit code 1', exitOf(nonTerminating.text) === 1, nonTerminating.text);
      await p.run({ shell, command: `& '${NODE}' '${CHILD}' exit 3` });
      const after = await p.run({ shell, command: "'no program here'" });
      check(shell + ': a command that runs no program reports 0, not the last program\'s 3', exitOf(after.text) === 0, after.text);
      const thrown = await p.run({ shell, command: "'before'; throw 'boom'" });
      check(shell + ': output before a throw is kept, and the throw makes exit code 1', /before/.test(thrown.text || '') && /boom/.test(thrown.text || '') && exitOf(thrown.text) === 1, thrown.text);
      const breaks = await p.run({ shell, command: "'one'; break; 'two'" });
      const still = await p.run({ shell, command: "'still here'" });
      check(shell + ': a stray break ends only the command, not the shell', /one/.test(breaks.text || '') && !/two/.test(breaks.text || '') && norm(outputOf(still.text)) === 'still here' && !/started a new/.test(still.text), breaks.text + ' | ' + still.text);
      const prefixes = await p.run({ shell, command: "Write-Warning 'w'; Write-Verbose 'v' -Verbose; & { $DebugPreference = 'Continue'; Write-Debug 'd' }" });
      check(shell + ': warnings, verbose and debug lines keep their prefixes', /WARNING: w/.test(prefixes.text || '') && /VERBOSE: v/.test(prefixes.text || '') && /DEBUG: d/.test(prefixes.text || ''), prefixes.text);
    }
    const loop = await p.run({ shell: 'bash', command: 'for i in 1 2; do echo $i; break; done; echo after; break; echo never' });
    const still = await p.run({ shell: 'bash', command: 'echo still here' });
    check('bash: break inside and outside a loop ends only the command', norm(outputOf(loop.text)) === '1\nafter' && norm(outputOf(still.text)) === 'still here' && !/started a new/.test(still.text), loop.text + ' | ' + still.text);
    const exited = await p.run({ shell: 'bash', command: 'exit 4' });
    check('bash: exit inside a command reports its code and that the shell ended', exitOf(exited.text) === 4 && /shell itself ended/.test(exited.text || ''), exited.text);
    const fresh = await p.run({ shell: 'bash', command: 'echo fresh' });
    check('bash: the next command starts a fresh shell and says why', norm(outputOf(fresh.text)) === 'fresh' && /started a new Git Bash/.test(fresh.text) && /ended \(exit code 4\)/.test(fresh.text), fresh.text);
    await p.close();
  }

  // ---- 6 -------------------------------------------------------------------------------------------
  if (section(6, 'every character arrives, and line endings are made uniform')) {
    const p = new Petal();
    await p.init();
    const tricky = 'é中😀 ✓ \u202Eright-to-left\u202C \u0000? no: tab\there "quotes" \'single\' `back` $dollar \\back\\slash';
    const safe = tricky.replace('\u0000', '');
    for (const shell of ['pwsh', 'powershell', 'bash']) {
      const cmd = shell === 'bash' ? `"${fwd(NODE)}" "${fwd(CHILD)}" print ${hex(safe + '\r\n')}` : `& '${NODE}' '${CHILD}' print '${hex(safe + '\r\n')}'`;
      const r = await p.run({ shell, command: cmd });
      check(shell + ': a program\'s UTF-8 output arrives exactly, its CRLF made LF', outputOf(r.text) === safe, JSON.stringify(outputOf(r.text)));
      const cmdEcho = await p.run({ shell, command: shell === 'bash' ? 'cmd //c echo é中' : 'cmd /c echo é中' });
      check(shell + ': cmd\'s own output arrives in UTF-8', norm(outputOf(cmdEcho.text)) === 'é中', JSON.stringify(outputOf(cmdEcho.text)));
    }
    const literal = await p.run({ shell: 'pwsh', command: "'" + safe.replace(/'/g, "''") + "'" });
    check('pwsh: the command text itself arrives with every character', outputOf(literal.text) === safe, JSON.stringify(outputOf(literal.text)));
    const bashLiteral = await p.run({ shell: 'bash', command: "printf '%s\\n' '" + safe.replace(/'/g, "'\\''") + "'" });
    check('bash: the command text itself arrives with every character', outputOf(bashLiteral.text) === safe, JSON.stringify(outputOf(bashLiteral.text)));
    const invalid = await p.run({ shell: 'bash', command: "printf 'bad \\x82 byte\\n'" });
    check('bash: a byte that is not UTF-8 becomes U+FFFD, the reply stays valid', outputOf(invalid.text) === 'bad \uFFFD byte', JSON.stringify(outputOf(invalid.text)));
    // A lone surrogate is valid JSON but not UTF-8, and Zig's parser rejects the whole request;
    // petal answers anyway, with U+FFFD in its place.
    const lone = await p.run({ shell: 'pwsh', command: "'x' # \ud800" });
    check('pwsh: a command holding a lone surrogate runs', norm(outputOf(lone.text)) === 'x', JSON.stringify(lone.text));
    const slow = p.run({ shell: 'pwsh', command: 'Start-Sleep -Seconds 2 # \ud800', timeout: 20000 }, { timeout: 30000 });
    await sleep(700);
    const busyLone = await p.run({ shell: 'pwsh', command: "'y'", timeout: 20000 }, { timeout: 30000 });
    check('a busy reply quoting that command is text, the surrogate shown as U+FFFD', (busyLone.text || '').includes('# \uFFFD`'), JSON.stringify(busyLone.text));
    await slow;
    await p.run({ shell: 'bash', command: "bad=$'\\x82'" });
    const quoted = await p.run({ shell: 'bash', command: `rm -rf "${fwd(WORK)}/$bad/none"` });
    check('bash: a check finding quoting a value that holds a byte that is not UTF-8 is text, the byte shown as U+FFFD', (quoted.text || '').includes(fwd(WORK) + '/\uFFFD/none'), JSON.stringify(quoted.text));
    const table = await p.run({ shell: 'powershell', command: 'Get-ChildItem $env:SystemRoot\\System32\\drivers\\etc | Select-Object -First 2 Name' });
    check('powershell: table rows carry no trailing spaces', !/ \n/.test(outputOf(table.text) + '\n') && /Name/.test(table.text || ''), JSON.stringify(outputOf(table.text)));
    await p.close();
  }

  // ---- 7 -------------------------------------------------------------------------------------------
  if (section(7, 'long output: the first and last of it, and all of it in a file')) {
    const p = new Petal();
    await p.init();
    const r = await p.run({ shell: 'bash', command: 'for i in $(seq 1 6000); do echo "line $i é"; done' });
    const out = outputOf(r.text);
    const units = out.length;
    check('the reply\'s output stays within 30,000 characters (plus the marker)', units <= 30100 && units > 29000, units);
    check('it starts at the first line and ends at the last', out.startsWith('line 1 é\nline 2 é\n') && out.endsWith('line 6000 é'), JSON.stringify(out.slice(0, 30)) + ' … ' + JSON.stringify(out.slice(-30)));
    check('a marker says how much is left out', /\[… \d+ characters in \d+ lines not shown …\]/.test(out), out.slice(9000, 10200));
    const m = /All of it: (.+\.txt)/.exec(r.text || '');
    const full = m && fs.existsSync(m[1]) ? fs.readFileSync(m[1], 'utf8') : '';
    check('the reply names a file holding every line', full.split('\n').filter(Boolean).length === 6000, m && m[1]);
    const short = await p.run({ shell: 'bash', command: 'echo short' });
    check('control: a short output comes whole, with no marker and no file named', norm(outputOf(short.text)) === 'short' && !/All of it/.test(short.text), short.text);
    await p.close();
  }

  // ---- 8 -------------------------------------------------------------------------------------------
  if (section(8, 'what a started program writes straight to the shell\'s own output is reported')) {
    const p = new Petal();
    await p.init();
    const r = await p.run({ shell: 'pwsh', command: "Start-Process -NoNewWindow -Wait -FilePath cmd -ArgumentList '/c','echo stray-output-é'" });
    check('it comes back marked as written straight to the shell\'s own output', /written straight to the shell's own output[^\n]*\nstray-output-é/.test(r.text || ''), r.text);
    check('the command\'s own output does not hold it', outputOf(r.text) === '(no output)', JSON.stringify(outputOf(r.text)));
    const next = await p.run({ shell: 'pwsh', command: "'clean'" });
    check('it is reported once, and a reply with nothing of the kind has no such note', !/stray-output/.test(next.text || '') && !/written straight/.test(next.text || ''), next.text);
    const late = await p.run({ shell: 'pwsh', command: `Start-Process -NoNewWindow -FilePath '${NODE}' -ArgumentList '${CHILD}','late','1500','${hex('late-stray-é\n')}'; 'started'` });
    check('a program still running when its command ends: nothing of it in that reply', norm(outputOf(late.text)) === 'started' && !/late-stray/.test(late.text || ''), late.text);
    await sleep(3000);
    const after = await p.run({ shell: 'pwsh', command: "'after'" });
    check('what it writes later comes with the next reply', /since the previous command in this shell ended:\nlate-stray-é/.test(after.text || ''), after.text);
    await p.close();
  }

  // ---- 9 -------------------------------------------------------------------------------------------
  if (section(9, 'the check before running')) {
    const p = new Petal();
    await p.init();
    const zone = path.join(WORK, 'checkzone');
    const victim = path.join(zone, 'victim');
    const reset = () => { fs.rmSync(zone, { recursive: true, force: true }); fs.mkdirSync(victim, { recursive: true }); fs.writeFileSync(path.join(victim, 'f.txt'), 'x'); };
    reset();
    for (const shell of ['pwsh', 'powershell']) {
      await p.run({ shell, command: `Set-Location '${zone}'; $empty = ''; $there = '${victim}'` });
      const marker = path.join(zone, 'ran-' + shell);
      const parse = await p.run({ shell, command: `New-Item -ItemType File '${marker}' | Out-Null; Get-Item 'unterminated` });
      check(shell + ': a command that does not parse is not run at all', parse.isError === true && /does not parse/.test(parse.text) && !fs.existsSync(marker), parse.text);
      const rel = await p.run({ shell, command: 'Remove-Item .\\victim -Recurse' });
      check(shell + ': a relative deletion is stopped, its absolute target shown, the folder still there', rel.isError === true && rel.text.includes(victim) && fs.existsSync(victim), rel.text);
      const empty = await p.run({ shell, command: `Remove-Item "${zone}\\$empty\\victim" -Recurse` });
      check(shell + ': a deletion through an empty variable is stopped and says it is empty', empty.isError === true && /\$empty is empty/.test(empty.text) && fs.existsSync(victim), empty.text);
      const known = await p.run({ shell, command: 'Remove-Item "$there\\f.txt"' });
      check(shell + ': a deletion through a variable shows what it resolves to now', known.isError === true && known.text.includes(path.join(victim, 'f.txt')) && fs.existsSync(path.join(victim, 'f.txt')), known.text);
      const setHere = await p.run({ shell, command: `$d = '${victim}'; Remove-Item $d -Recurse` });
      check(shell + ': a variable the command sets itself is named as such', setHere.isError === true && /gets its value only as this command runs/.test(setHere.text) && fs.existsSync(victim), setHere.text);
      const absolute = await p.run({ shell, command: `Remove-Item '${path.join(zone, 'nothing')}' -ErrorAction SilentlyContinue; 'ran'` });
      check(shell + ': control: a deletion by a literal absolute path runs', norm(outputOf(absolute.text)) === 'ran', absolute.text);
      const intended = await p.run({ shell, command: 'Remove-Item .\\victim -Recurse', intended: true });
      check(shell + ': sent again as intended, it runs', intended.isError === false && !fs.existsSync(victim), intended.text);
      reset();
    }
    const quotes = await p.run({ shell: 'powershell', command: `& '${NODE}' -e 'console.log("x")'` });
    check('powershell: double quotes inside an argument to a program are flagged', quotes.isError === true && /removes the double quotes/.test(quotes.text), quotes.text);
    const quotes7 = await p.run({ shell: 'pwsh', command: `& '${NODE}' -e 'console.log("x")'` });
    check('pwsh: control: the same command runs in PowerShell 7', norm(outputOf(quotes7.text)) === 'x', quotes7.text);
    const enc = await p.run({ shell: 'powershell', command: `'x' | Out-File '${path.join(zone, 'o.txt')}'` });
    check('powershell: a write with no encoding is flagged and not made', enc.isError === true && /UTF-16/.test(enc.text) && !fs.existsSync(path.join(zone, 'o.txt')), enc.text);
    const round = await p.run({ shell: 'powershell', command: `(Get-Content '${path.join(zone, 'o.txt')}') | Set-Content '${path.join(zone, 'o.txt')}' -Encoding utf8` });
    check('powershell: the read-then-write round trip is flagged', round.isError === true && /Get-Content reads a UTF-8 file/.test(round.text), round.text);
    const enc7 = await p.run({ shell: 'pwsh', command: `'x' | Out-File '${path.join(zone, 'o7.txt')}'; 'wrote'` });
    check('pwsh: control: PowerShell 7 writes it without a finding', norm(outputOf(enc7.text)) === 'wrote', enc7.text);
    await p.run({ shell: 'bash', command: `cd "${fwd(zone)}"; there="${fwd(victim)}"` });
    const bsyntax = await p.run({ shell: 'bash', command: `touch "${fwd(path.join(zone, 'bash-ran'))}"; if true; then echo x` });
    check('bash: a command that does not parse is not run at all', bsyntax.isError === true && /does not parse/.test(bsyntax.text) && !fs.existsSync(path.join(zone, 'bash-ran')), bsyntax.text);
    const brel = await p.run({ shell: 'bash', command: 'rm -rf victim' });
    check('bash: a relative deletion is stopped and the folder still there', brel.isError === true && /relative path/.test(brel.text) && fs.existsSync(victim), brel.text);
    const bvar = await p.run({ shell: 'bash', command: 'rm -rf "$there"/f.txt' });
    check('bash: a deletion through a variable shows what it resolves to', bvar.isError === true && bvar.text.includes(fwd(victim) + '/f.txt') && fs.existsSync(path.join(victim, 'f.txt')), bvar.text);
    const bempty = await p.run({ shell: 'bash', command: `rm -rf "${fwd(zone)}/$nothing_here/victim"` });
    check('bash: an unset variable is named', bempty.isError === true && /\$nothing_here is empty or unset/.test(bempty.text) && fs.existsSync(victim), bempty.text);
    const bsub = await p.run({ shell: 'bash', command: 'rm -rf "$(pwd)"/victim' });
    check('bash: a target that would need code run is reported as unresolvable', bsub.isError === true && /would mean running code/.test(bsub.text) && fs.existsSync(victim), bsub.text);
    const bquoted = await p.run({ shell: 'bash', command: "echo 'rm -rf /'" });
    check('bash: control: rm inside a quoted string is not a deletion', norm(outputOf(bquoted.text)) === 'rm -rf /', bquoted.text);
    const bintended = await p.run({ shell: 'bash', command: 'rm -rf victim', intended: true });
    check('bash: sent again as intended, it runs', bintended.isError === false && !fs.existsSync(victim), bintended.text);
    await p.close();

    // A read of a Claude Code transcript with a reader that keeps Claude Code from writing to it.
    // The transcripts here are in a configuration folder of the test's own, named by
    // CLAUDE_CONFIG_DIR as Claude Code's is; without it, petal looks under .claude in USERPROFILE.
    const config = path.join(tmp, 'claude-config');
    const transcripts = path.join(config, 'projects', 'C--test');
    const transcript = path.join(transcripts, 'session.jsonl');
    const elsewhere = path.join(zone, 'elsewhere.jsonl');
    fs.mkdirSync(transcripts, { recursive: true });
    fs.writeFileSync(transcript, '{"n":1}\n{"n":2}\n');
    fs.writeFileSync(elsewhere, '{"n":1}\n');
    fs.writeFileSync(path.join(transcripts, 'notes.md'), 'notes\n');
    fs.mkdirSync(path.join(transcripts, 'memory'), { recursive: true });
    fs.writeFileSync(path.join(transcripts, 'memory', 'a.md'), 'a\n');
    fs.writeFileSync(path.join(zone, 'notes.txt'), 'notes\n');
    const sha = (file) => require('crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase();
    const append = (file) => { try { fs.appendFileSync(file, '{"appended":true}\n'); return true; } catch (e) { return false; } };
    const t = new Petal({ CLAUDE_CONFIG_DIR: config });
    await t.init();
    const named = 'opens ' + transcript + ', a Claude Code transcript';
    for (const shell of ['pwsh', 'powershell']) {
      const lines = await t.run({ shell, command: `foreach ($l in [IO.File]::ReadLines('${transcript}')) { break }; 'ran'` });
      check(shell + ': ReadLines on a transcript is stopped, naming the file and why', lines.isError === true && lines.text.includes('[IO.File]::ReadLines ' + named) && /missing from the transcript until the session's next compaction, which writes it again when that compaction keeps any message newer than it; otherwise, or if the session ends first, it is lost/.test(lines.text), lines.text);
      const viaVariable = await t.run({ shell, command: `$p = '${transcript}'; $text = [IO.File]::ReadAllText($p); 'ran'` });
      check(shell + ': a transcript named through a variable the command sets is shown by its path', viaVariable.isError === true && viaVariable.text.includes(named), viaVariable.text);
      const sw = await t.run({ shell, command: `switch -File '${transcript}' { default { break } }; 'ran'` });
      check(shell + ': switch -File on a transcript is stopped', sw.isError === true && sw.text.includes('switch -File ' + named), sw.text);
      const reader = await t.run({ shell, command: `$r = New-Object IO.StreamReader('${transcript}'); $r.Dispose(); 'ran'` });
      check(shell + ': New-Object IO.StreamReader on a transcript is stopped', reader.isError === true && reader.text.includes('New-Object IO.StreamReader ' + named), reader.text);
      await t.run({ shell, command: `Set-Location '${transcripts}'` });
      const found = await t.run({ shell, command: `$f = Get-ChildItem -Filter *.jsonl | Select-Object -First 1; $null = [IO.File]::ReadAllLines($f.FullName); 'ran'` });
      check(shell + ': a reader of a file found as the command runs is stopped when the command names .jsonl', found.isError === true && /cannot name before the command runs, and the command names a \.jsonl file/.test(found.text), found.text);
      await t.run({ shell, command: `Set-Location '${WORK}'` });
      const inFolder = await t.run({ shell, command: `$f = (Get-ChildItem '${transcripts}')[0]; $null = [IO.File]::ReadAllLines($f.FullName); 'ran'` });
      check(shell + ': and when the command names the transcripts\' folder', inFolder.isError === true && /the command names the folder of Claude Code's transcripts/.test(inFolder.text), inFolder.text);
      const held = await t.run({ shell, command: `$b = [IO.File]::OpenRead('${transcript}'); 'held'`, intended: true });
      const heldAppend = append(transcript);
      await t.run({ shell, command: '$b.Dispose()' });
      check(shell + ': control: sent as intended, OpenRead holds the transcript and an append is refused', norm(outputOf(held.text)) === 'held' && !heldAppend, held.text);
      const shared = await t.run({ shell, command: `$s = [IO.FileStream]::new('${transcript}', 'Open', 'Read', 'ReadWrite, Delete'); $r = [IO.StreamReader]::new($s); $null = $r.ReadLine(); 'held'` });
      const sharedAppend = append(transcript);
      const rest = await t.run({ shell, command: '$r.ReadToEnd(); $r.Dispose(); $s.Dispose()' });
      check(shell + ': control: the stream the finding suggests runs, and the transcript takes an append while it is open', norm(outputOf(shared.text)) === 'held' && sharedAppend && outputOf(rest.text).includes('"appended":true'), shared.text + ' | ' + rest.text);
      const content = await t.run({ shell, command: `(Get-Content '${transcript}' | Measure-Object).Count` });
      check(shell + ': control: Get-Content on a transcript runs', content.isError === false && Number(norm(outputOf(content.text))) >= 3, content.text);
      const other = await t.run({ shell, command: `foreach ($l in [IO.File]::ReadLines('${elsewhere}')) { break }; 'ran'` });
      check(shell + ': control: the same reader on a .jsonl file outside the transcripts runs', norm(outputOf(other.text)) === 'ran', other.text);
      const markdown = await t.run({ shell, command: `foreach ($n in 'notes') { $null = [IO.File]::ReadAllText("${transcripts}\\$n.md") }; 'ran'` });
      check(shell + ': control: a reader of a .md file in the transcripts\' folder, named through a loop variable, runs', norm(outputOf(markdown.text)) === 'ran', markdown.text);
      const fixedEnd = await t.run({ shell, command: `$null = [IO.File]::ReadAllText("$((Get-Item '${transcripts}').FullName)\\notes.md"); 'ran'` });
      check(shell + ': control: a reader whose path ends in .md after code petal does not run runs', norm(outputOf(fixedEnd.text)) === 'ran', fixedEnd.text);
      const mdNamed = await t.run({ shell, command: `$f = Get-Item '${transcripts}\\notes.md'; $null = [IO.File]::ReadAllText($f.FullName); 'ran'` });
      check(shell + ': control: a reader of a file found as the command runs, in a command naming only a .md file in the transcripts\' folder, runs', norm(outputOf(mdNamed.text)) === 'ran', mdNamed.text);
      const regexText = await t.run({ shell, command: `$f = Get-Item '${path.join(zone, 'notes.txt')}'; $text = [IO.File]::ReadAllText($f.FullName); [bool]($text -match '\\.jsonl')` });
      check(shell + ': control: a command naming .jsonl only as regex text runs', norm(outputOf(regexText.text)) === 'False', regexText.text);
      const intended = await t.run({ shell, command: `$n = 0; foreach ($l in [IO.File]::ReadLines('${transcript}')) { $n++ }; $n`, intended: true });
      check(shell + ': sent again as intended, it runs', intended.isError === false && Number(norm(outputOf(intended.text))) >= 3, intended.text);

      // The cmdlets Copy-Item and Get-FileHash, which keep other programs from writing to each file
      // while they read it, as the readers above do.
      const copied = path.join(zone, 'copied-' + shell + '.jsonl');
      const copy = await t.run({ shell, command: `Copy-Item '${transcript}' '${copied}'; 'ran'` });
      check(shell + ': Copy-Item of a transcript is stopped, naming the file and why, and copies nothing', copy.isError === true && copy.text.includes('Copy-Item reads ' + transcript + ', a Claude Code transcript') && /missing from the transcript until the session's next compaction, which writes it again when that compaction keeps any message newer than it; otherwise, or if the session ends first, it is lost/.test(copy.text) && !fs.existsSync(copied), copy.text);
      const hash = await t.run({ shell, command: `Get-FileHash -LiteralPath '${transcript}'` });
      check(shell + ': Get-FileHash of a transcript is stopped', hash.isError === true && hash.text.includes('Get-FileHash reads ' + transcript + ', a Claude Code transcript'), hash.text);
      const wild = await t.run({ shell, command: `Get-FileHash '${transcripts}\\*'` });
      check(shell + ': a -Path wildcard is matched against the folder, and its transcript named', wild.isError === true && wild.text.includes('Get-FileHash reads ' + transcript + ','), wild.text);
      const tree = await t.run({ shell, command: `Copy-Item '${config}' '${path.join(zone, 'tree-' + shell)}' -Recurse; 'ran'` });
      check(shell + ': Copy-Item -Recurse of a folder holding transcripts is stopped', tree.isError === true && tree.text.includes('Copy-Item -Recurse copies ' + config + ' with everything in it'), tree.text);
      const piped = await t.run({ shell, command: `Get-ChildItem '${transcripts}' -Filter *.jsonl | Get-FileHash` });
      check(shell + ': Get-FileHash of files piped in is stopped when the command names .jsonl', piped.isError === true && /Get-FileHash hashes files petal cannot name before the command runs, and the command names a \.jsonl file/.test(piped.text), piped.text);
      const looped = await t.run({ shell, command: `foreach ($p in '${transcript}') { $null = Get-FileHash -LiteralPath $p }; 'ran'` });
      check(shell + ': a loop variable is read from the list the loop runs over', looped.isError === true && looped.text.includes('Get-FileHash reads ' + transcript + ','), looped.text);
      const listed = await t.run({ shell, command: `Copy-Item -Path '${transcripts}\\notes.md', '${transcript}' -Destination '${zone}'; 'ran'` });
      check(shell + ': each path of a list is checked', listed.isError === true && listed.text.includes('Copy-Item reads ' + transcript + ','), listed.text);
      await t.run({ shell, command: `$global:pair = @('${transcripts}\\notes.md', '${transcript}')` });
      const held2 = await t.run({ shell, command: 'Get-FileHash $pair' });
      check(shell + ': a list the shell holds in a variable is checked', held2.isError === true && held2.text.includes('Get-FileHash reads ' + transcript + ','), held2.text);
      const mdCopy = await t.run({ shell, command: `Copy-Item '${transcripts}\\notes.md' '${path.join(zone, 'notes-' + shell + '.md')}'; 'ran'` });
      check(shell + ': control: Copy-Item of a .md file in the transcripts\' folder runs', norm(outputOf(mdCopy.text)) === 'ran' && fs.existsSync(path.join(zone, 'notes-' + shell + '.md')), mdCopy.text);
      const memCopy = await t.run({ shell, command: `Copy-Item '${path.join(transcripts, 'memory')}' '${path.join(zone, 'memory-' + shell)}' -Recurse; 'ran'` });
      check(shell + ': control: Copy-Item -Recurse of a folder there that holds no transcript runs', norm(outputOf(memCopy.text)) === 'ran' && fs.existsSync(path.join(zone, 'memory-' + shell, 'a.md')), memCopy.text);
      const streamHash = await t.run({ shell, command: `$s = [IO.FileStream]::new('${transcript}', 'Open', 'Read', 'ReadWrite, Delete'); (Get-FileHash -InputStream $s).Hash; $s.Dispose()` });
      check(shell + ': control: hashing through the stream the finding suggests runs and gives the file\'s SHA-256', streamHash.isError === false && norm(outputOf(streamHash.text)) === sha(transcript), streamHash.text);
      const safe = path.join(zone, 'safe-' + shell + '.jsonl');
      const streamCopy = await t.run({ shell, command: `$s = [IO.FileStream]::new('${transcript}', 'Open', 'Read', 'ReadWrite, Delete'); $d = [IO.File]::Create('${safe}'); $s.CopyTo($d); $d.Dispose(); $s.Dispose(); 'copied'` });
      check(shell + ': control: copying through the stream the finding suggests runs and copies the file whole', norm(outputOf(streamCopy.text)) === 'copied' && fs.existsSync(safe) && sha(safe) === sha(transcript), streamCopy.text);
      const hashIntended = await t.run({ shell, command: `(Get-FileHash -LiteralPath '${transcript}').Hash`, intended: true });
      check(shell + ': Get-FileHash of a transcript sent again as intended runs', hashIntended.isError === false && norm(outputOf(hashIntended.text)) === sha(transcript), hashIntended.text);
    }
    await t.close();
    const home = path.join(tmp, 'home');
    const homeTranscript = path.join(home, '.claude', 'projects', 'C--test', 'session.jsonl');
    fs.mkdirSync(path.dirname(homeTranscript), { recursive: true });
    fs.writeFileSync(homeTranscript, '{"n":1}\n');
    const u = new Petal({ CLAUDE_CONFIG_DIR: null, USERPROFILE: home });
    await u.init();
    const homeRead = await u.run({ command: `[IO.File]::ReadAllText('${homeTranscript}')` });
    check('pwsh: with CLAUDE_CONFIG_DIR unset, a transcript under .claude in USERPROFILE is stopped', homeRead.isError === true && homeRead.text.includes('opens ' + homeTranscript + ', a Claude Code transcript'), homeRead.text);
    await u.close();
  }

  // ---- 10 ------------------------------------------------------------------------------------------
  if (section(10, 'stamens: each agent\'s own shells, busy shells, copies, and running side by side')) {
    const p = new Petal();
    await p.init();
    const a1 = path.join(WORK, 'agent-main');
    fs.mkdirSync(a1, { recursive: true });
    await p.run({ command: `$secret = 'main only'; $env:PETAL_TEST_COPY = 'copied é'; Set-Location '${a1}'` });
    const sub = await p.tool('run', { command: '"[$secret] [$env:PETAL_TEST_COPY] $((Get-Location).Path)"', agent: 'sub1', agent_type: 'Explore' });
    check('a subagent has shells of its own: none of the main agent\'s variables, folder or environment', /^\[\] \[\] /.test(outputOf(sub.text)) && !outputOf(sub.text).includes(a1) && /stamen sub1/.test(sub.text), sub.text);
    const long = p.run({ command: 'Start-Sleep -Seconds 4; "slept"', timeout: 20000 }, { timeout: 30000 });
    await sleep(1500);
    const busy = await p.run({ command: "'second'", timeout: 20000 }, { timeout: 30000 });
    check('a second call to a busy shell is answered at once that it is busy, with what and how to go on', busy.isError === true && /is busy with `Start-Sleep -Seconds 4; "slept"`/.test(busy.text) && /"from": "main"/.test(busy.text), busy.text);
    const side = await p.run({ command: '"[$secret] [$env:PETAL_TEST_COPY] $((Get-Location).Path)"', stamen: 'side', from: 'main' });
    check('a new stamen from main copies its folder and environment variables, not its variables', outputOf(side.text) === '[] [copied é] ' + a1 && /stamen main:side/.test(side.text), side.text);
    const longDone = await long;
    check('the busy command finishes normally', norm(outputOf(longDone.text)) === 'slept', longDone.text);
    // Each command reports when it began and ended its sleep. Whatever the load on the machine,
    // the two spans overlap only if petal ran the commands side by side.
    const span = '$from = [DateTimeOffset]::Now.ToUnixTimeMilliseconds(); Start-Sleep -Seconds 3; "$from $([DateTimeOffset]::Now.ToUnixTimeMilliseconds())"';
    const [x, y] = await Promise.all([p.run({ command: span, stamen: 'par1' }), p.run({ command: span, stamen: 'par2' })]);
    const [xFrom, xTo] = norm(outputOf(x.text)).split(' ').map(Number);
    const [yFrom, yTo] = norm(outputOf(y.text)).split(' ').map(Number);
    const spans = [xFrom, xTo, yFrom, yTo];
    check('two stamens run side by side: their two 3-second commands overlap in time', spans.every((n) => n > 0) && xFrom < yTo && yFrom < xTo, JSON.stringify(spans) + ' | ' + x.text + ' | ' + y.text);
    const badName = await p.run({ command: "'x'", stamen: 'has:colon' });
    check('a stamen name with ":" is refused', badName.isError === true && /cannot name a stamen/.test(badName.text), badName.text);
    const noSource = await p.run({ command: "'x'", stamen: 'other', from: 'nobody' });
    check('from a stamen that does not exist is refused', noSource.isError === true && /no stamen "nobody"/.test(noSource.text), noSource.text);
    await p.close();
    const q = new Petal();
    await q.init();
    const first = await q.tool('run', { command: "'x'" });
    const second = await q.tool('run', { command: "'y'" });
    check('without the hook, petal says once that it used the main agent\'s shells', /no agent identity/.test(first.text) && !/no agent identity/.test(second.text), first.text + ' | ' + second.text);
    await q.close();
  }

  // ---- 11 ------------------------------------------------------------------------------------------
  if (section(11, 'a timeout ends the command, its shell and everything it started')) {
    const p = new Petal();
    await p.init();
    const sub = path.join(WORK, 'timeouts');
    fs.mkdirSync(sub, { recursive: true });
    for (const shell of ['pwsh', 'bash']) {
      const pidFile = path.join(tmp, 'pid-timeout-' + shell);
      await p.run({ shell, command: shell === 'bash' ? `cd "${fwd(sub)}"; marker=kept` : `Set-Location '${sub}'; $marker = 'kept'` });
      const r = await p.run({ shell, command: shell === 'bash' ? `"${fwd(NODE)}" "${fwd(CHILD)}" sleep "${fwd(pidFile)}"` : `& '${NODE}' '${CHILD}' sleep '${pidFile}'`, timeout: 2500 }, { timeout: 30000 });
      const pid = fs.existsSync(pidFile) ? Number(fs.readFileSync(pidFile, 'utf8')) : 0;
      check(shell + ': the reply says the command did not finish and is an error', r.isError === true && /did not finish within 2 s/.test(r.text || ''), r.text);
      check(shell + ': the program the command started is gone', pid > 0 && await waitFor(() => !alive(pid), 5000), 'pid ' + pid);
      const after = await p.run({ shell, command: shell === 'bash' ? 'echo "[$marker] $(pwd -W)"' : '"[$marker] $((Get-Location).Path)"' });
      check(shell + ': the next command gets a fresh shell in the same folder, without the variable', outputOf(after.text) === '[] ' + (shell === 'bash' ? fwd(sub) : sub) && /ran past its timeout/.test(after.text), after.text);
    }
    const control = spawn(NODE, [CHILD, 'sleep', path.join(tmp, 'pid-control')], { windowsHide: true });
    await waitFor(() => fs.existsSync(path.join(tmp, 'pid-control')), 5000);
    check('control: the sleeping program stays alive when nothing ends it', alive(control.pid));
    control.kill();
    await p.close();
  }

  // ---- 12 ------------------------------------------------------------------------------------------
  if (section(12, 'cancelling a call ends its command and gets no answer')) {
    const p = new Petal();
    await p.init();
    const pidFile = path.join(tmp, 'pid-cancel');
    const pending = p.request('tools/call', { name: 'run', arguments: { agent: 'main', command: `& '${NODE}' '${CHILD}' sleep '${pidFile}'` } }, { id: 'cancel-me', timeout: 8000 });
    await waitFor(() => fs.existsSync(pidFile), 10000);
    p.send({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 'cancel-me', reason: 'test' } });
    const answer = await pending;
    const pid = fs.existsSync(pidFile) ? Number(fs.readFileSync(pidFile, 'utf8')) : 0;
    check('the cancelled call gets no answer', answer === null, JSON.stringify(answer));
    check('the program it started is gone', pid > 0 && await waitFor(() => !alive(pid), 5000), 'pid ' + pid);
    const after = await p.run({ command: "'after'" });
    check('the next command runs in a fresh shell and says why', norm(outputOf(after.text)) === 'after' && /was cancelled/.test(after.text), after.text);
    const keep = p.request('tools/call', { name: 'run', arguments: { agent: 'main', command: "Start-Sleep -Milliseconds 1500; 'not cancelled'" } }, { id: 'keep-me' });
    await sleep(500);
    p.send({ jsonrpc: '2.0', method: 'notifications/cancelled', params: { requestId: 'nobody', reason: 'test' } });
    const other = await keep;
    check('control: a cancellation for another id, sent while a call runs, leaves it alone', other && /not cancelled/.test(other.result.content[0].text), JSON.stringify(other));
    await p.close();
  }

  // ---- 13 ------------------------------------------------------------------------------------------
  if (section(13, 'progress during a long command')) {
    const p = new Petal();
    await p.init();
    const r = await p.run({ command: 'Start-Sleep -Seconds 11; "done"' }, { token: 'tok-1' });
    const progress = p.notifications.filter((m) => m.method === 'notifications/progress');
    check('a call with a progress token gets progress at 10 s', norm(outputOf(r.text)) === 'done' && progress.length >= 1 && progress[0].params.progressToken === 'tok-1' && progress[0].params.progress === 10, JSON.stringify(progress));
    const before = p.notifications.length;
    await p.run({ command: 'Start-Sleep -Seconds 11; "done"' });
    check('control: a call without one gets none', p.notifications.length === before, JSON.stringify(p.notifications.slice(before)));
    await p.close();
  }

  // ---- 14 ------------------------------------------------------------------------------------------
  if (section(14, 'messages in the inbox ride on the next reply, once')) {
    const p = new Petal();
    await p.init();
    await p.run({ command: "'warm'" });
    const inbox = path.join(p.sessionDir, 'inbox');
    fs.writeFileSync(path.join(inbox, '0002.tmp'), 'second message');
    fs.renameSync(path.join(inbox, '0002.tmp'), path.join(inbox, '0002.msg'));
    fs.writeFileSync(path.join(inbox, '0001.tmp'), '\uFEFFfirst é中😀\nline two');
    fs.renameSync(path.join(inbox, '0001.tmp'), path.join(inbox, '0001.msg'));
    fs.writeFileSync(path.join(inbox, 'unfinished.tmp'), 'not yet');
    const r = await p.tool('shells', {});
    const firstAt = (r.text || '').indexOf('first é中😀\nline two');
    check('both messages come, oldest name first, after the reply', firstAt > 0 && (r.text || '').indexOf('second message') > firstAt && /A message from the user, sent at \d\d:\d\d:\d\d:/.test(r.text), r.text);
    check('a file not yet renamed to .msg is left alone', !/not yet/.test(r.text || '') && fs.existsSync(path.join(inbox, 'unfinished.tmp')));
    check('delivered messages move to the delivered folder', fs.existsSync(path.join(inbox, 'delivered', '0001.msg')) && !fs.existsSync(path.join(inbox, '0001.msg')));
    const next = await p.run({ command: "'again'" });
    check('a message comes once', !/first é中/.test(next.text || ''), next.text);
    await p.close();
  }

  // ---- 15 ------------------------------------------------------------------------------------------
  if (section(15, 'restart, and the shells listing')) {
    const p = new Petal();
    await p.init();
    const sub = path.join(WORK, 'restarts');
    fs.mkdirSync(sub, { recursive: true });
    await p.run({ command: `$gone = 'x'; Set-Location '${sub}'` });
    await p.run({ shell: 'bash', command: 'echo hi' });
    const list = await p.tool('shells', {});
    check('the listing names the stamen, its shells, their state and folder', /stamen main, of the main agent/.test(list.text) && /pwsh: running, idle; folder /.test(list.text) && list.text.includes(sub) && /powershell: not started/.test(list.text) && /bash: running, idle/.test(list.text), list.text);
    const r = await p.tool('restart', { agent: 'main', shell: 'pwsh' });
    check('restart starts the shell fresh in its folder', /pwsh: restarted; started a new PowerShell/.test(r.text) && r.text.includes(sub), r.text);
    const after = await p.run({ command: '"[$gone] $((Get-Location).Path)"' });
    check('after it, the variable is gone and the folder kept', outputOf(after.text) === '[] ' + sub && !/started a new/.test(after.text), after.text);
    const none = await p.tool('restart', { agent: 'nobody' });
    check('restarting a stamen that never ran is refused', none.isError === true, none.text);
    await p.close();
  }

  // ---- 16 ------------------------------------------------------------------------------------------
  if (section(16, 'the hook writes the calling agent into the call')) {
    const hook = (input) => spawnSync(PETAL, ['hook'], { input, encoding: 'utf8', windowsHide: true });
    const sub = hook(JSON.stringify({ session_id: 's', tool_name: 'mcp__petal__run', tool_input: { command: 'ls', agent: 'forged' }, agent_id: 'a1b2', agent_type: 'Explore' }));
    const subOut = sub.stdout ? JSON.parse(sub.stdout) : null;
    check('a subagent\'s call gets its id and type, and a forged agent is overwritten', subOut && subOut.hookSpecificOutput.hookEventName === 'PreToolUse' && JSON.stringify(subOut.hookSpecificOutput.updatedInput) === '{"command":"ls","agent":"a1b2","agent_type":"Explore"}', sub.stdout);
    const main = hook(JSON.stringify({ session_id: 's', tool_name: 'mcp__petal__run', tool_input: { command: 'ls' }, agent_type: 'general-purpose' }));
    check('the main agent\'s call gets "main" and no type', main.stdout && JSON.stringify(JSON.parse(main.stdout).hookSpecificOutput.updatedInput) === '{"command":"ls","agent":"main"}', main.stdout);
    const broken = hook('not json');
    check('input it cannot read leaves the call as it was: no output, exit 0', broken.status === 0 && broken.stdout === '', broken.stdout);
    check('`petal version` prints the version', /^petal \d+\.\d+\.\d+/.test(spawnSync(PETAL, ['version'], { encoding: 'utf8' }).stdout));
  }

  // ---- 17 ------------------------------------------------------------------------------------------
  if (section(17, 'what each shell\'s environment holds')) {
    const fake = path.join(tmp, 'fake-claude');
    fs.mkdirSync(fake, { recursive: true });
    fs.copyFileSync(NODE, path.join(fake, 'claude.exe'));
    const claude = spawn(path.join(fake, 'claude.exe'), [CHILD, 'sleep', path.join(tmp, 'pid-claude')], { windowsHide: true });
    await waitFor(() => fs.existsSync(path.join(tmp, 'pid-claude')), 5000);
    const p = new Petal({ CLAUDE_PID: String(claude.pid), PWD: fwd(WORK) });
    await p.init();
    for (const shell of ['pwsh', 'bash']) {
      const cmd = shell === 'bash' ? `"${fwd(NODE)}" "${fwd(CHILD)}" env CLAUDE_CODE_EXECPATH POWERSHELL_TELEMETRY_OPTOUT PETAL_LOOP PETAL_IN PETAL_OUT` : `& '${NODE}' '${CHILD}' env CLAUDE_CODE_EXECPATH POWERSHELL_TELEMETRY_OPTOUT PETAL_LOOP PETAL_IN PETAL_OUT`;
      const r = await p.run({ shell, command: cmd });
      const lines = norm(outputOf(r.text));
      check(shell + ': CLAUDE_CODE_EXECPATH names the Claude Code that started petal', lines.includes('CLAUDE_CODE_EXECPATH=' + path.join(fake, 'claude.exe')), lines);
      check(shell + ': POWERSHELL_TELEMETRY_OPTOUT is 1', lines.includes('POWERSHELL_TELEMETRY_OPTOUT=1'), lines);
      check(shell + ': petal\'s own loop variables are gone before any command runs', /PETAL_LOOP unset\nPETAL_IN unset\nPETAL_OUT unset/.test(lines), lines);
    }
    const pwd = await p.run({ shell: 'bash', command: 'echo "$PWD"' });
    check('bash: a PWD naming the start folder in Windows form does not make Bash report that form', norm(outputOf(pwd.text)).startsWith('/'), pwd.text);
    claude.kill();
    // As Claude Code starts its MCP servers: petal is the child of a claude.exe, and gets no CLAUDE_PID.
    const viaClaude = new Petal({}, { command: path.join(fake, 'claude.exe'), args: [CHILD, 'relay', PETAL] });
    await viaClaude.init();
    const fromParent = await viaClaude.run({ command: `& '${NODE}' '${CHILD}' env CLAUDE_CODE_EXECPATH CLAUDE_PID` });
    check('started by a claude.exe with no CLAUDE_PID, as Claude Code starts it, petal names its parent in CLAUDE_CODE_EXECPATH', norm(outputOf(fromParent.text)) === 'CLAUDE_CODE_EXECPATH=' + path.join(fake, 'claude.exe') + '\nCLAUDE_PID unset', fromParent.text);
    const q = new Petal({ CLAUDE_PID: String(process.pid) });
    await q.init();
    const notClaude = await q.run({ command: `& '${NODE}' '${CHILD}' env CLAUDE_CODE_EXECPATH` });
    check('control: when neither CLAUDE_PID nor petal\'s parent is a claude.exe, nothing is set', norm(outputOf(notClaude.text)) === 'CLAUDE_CODE_EXECPATH unset', notClaude.text);
    await p.close();
    await viaClaude.close();
    await q.close();
  }

  // ---- 18 ------------------------------------------------------------------------------------------
  if (section(18, 'an idle stamen\'s shells end on their own; the main agent\'s do not')) {
    const p = new Petal({ PETAL_IDLE_LIMIT_MS: '2000' });
    await p.init();
    await p.run({ command: "'main'" });
    await p.tool('run', { command: "'sub'", agent: 'sub9' });
    await sleep(4500);
    const list = await p.tool('shells', {});
    check('the subagent\'s shell has ended', /stamen sub9[\s\S]*pwsh: ended: this stamen's shells ended after/.test(list.text), list.text);
    check('the main agent\'s shell still runs', /stamen main, of the main agent\n  pwsh: running, idle/.test(list.text), list.text);
    const back = await p.tool('run', { command: "'back'", agent: 'sub9' });
    check('used again, it starts fresh and says why', norm(outputOf(back.text)) === 'back' && /ended after 0 minutes unused/.test(back.text), back.text);
    await p.close();
  }

  // ---- 19 ------------------------------------------------------------------------------------------
  if (section(19, 'the session ends with petal, and leaves its log')) {
    const p = new Petal();
    await p.init();
    const pidFile = path.join(tmp, 'pid-end');
    const pending = p.run({ shell: 'bash', command: `"${fwd(NODE)}" "${fwd(CHILD)}" sleep "${fwd(pidFile)}"` });
    await waitFor(() => fs.existsSync(pidFile), 10000);
    const pid = Number(fs.readFileSync(pidFile, 'utf8'));
    const code = await p.close();
    check('closing petal\'s standard input ends it, exit code 0', code === 0, code);
    check('a program a command was still running is gone', await waitFor(() => !alive(pid), 5000), 'pid ' + pid);
    void pending;
    const log = fs.readFileSync(path.join(p.sessionDir, 'log.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
    const events = log.map((r) => r.event);
    check('the log records the session, the shell, the run and the end', events[0] === 'session started' && events.includes('shell started') && events[events.length - 1] === 'session ended', events.join(', '));
    check('every record carries a local time with its offset', log.every((r) => /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}[+-]\d\d:\d\d$/.test(r.time)), log[0] && log[0].time);
    // Both folders are the test's own, so no build, broken or not, writes into the account's.
    const profile = path.join(tmp, 'profile');
    const local = path.join(tmp, 'localappdata');
    fs.mkdirSync(profile, { recursive: true });
    fs.mkdirSync(local, { recursive: true });
    const d = new Petal({ PETAL_DATA_DIR: null, USERPROFILE: profile, LOCALAPPDATA: local });
    await d.init();
    await d.close();
    const defaultLog = path.join(profile, '.petal', 'sessions', d.sessionId, 'log.jsonl');
    check('with no PETAL_DATA_DIR, petal keeps its data in .petal in the profile folder', fs.existsSync(defaultLog) && /"event":"session started"/.test(fs.readFileSync(defaultLog, 'utf8')), defaultLog);
    check('control: nothing is written under %LOCALAPPDATA%', !fs.existsSync(path.join(local, 'petal')), fs.existsSync(local) ? fs.readdirSync(local).join(', ') : '');
  }

  // ---- 20 ------------------------------------------------------------------------------------------
  if (section(20, 'memory does not grow with use')) {
    const p = new Petal();
    await p.init();
    for (let i = 0; i < 10; i++) await p.run({ shell: 'bash', command: "head -c 300000 /dev/zero | tr '\\0' 'x' | fold -w 100" });
    const mb = () => Number(execFileSync(SHELLS.pwsh, ['-NoProfile', '-Command', `(Get-Process -Id ${p.proc.pid}).PrivateMemorySize64`]).toString().trim()) / 1048576;
    const before = mb();
    for (let i = 0; i < 150; i++) await p.run({ shell: 'bash', command: "head -c 300000 /dev/zero | tr '\\0' 'x' | fold -w 100" });
    const after = mb();
    check('150 calls of 300 KB output each leave petal\'s private memory within 20 MB of where it was', after - before < 20, before.toFixed(1) + ' MB -> ' + after.toFixed(1) + ' MB');
    await p.close();
  }

  // ---- 21 ------------------------------------------------------------------------------------------
  if (section(21, 'a file a command leaves open is closed before the reply')) {
    const p = new Petal();
    await p.init();
    const f = path.join(WORK, 'held.jsonl');
    fs.writeFileSync(f, '{"n":1}\n{"n":2,"marker":"here"}\n{"n":3}\n');
    const append = () => { try { fs.appendFileSync(f, '{"appended":true}\n'); return 'works'; } catch (e) { return e.code; } };
    for (const shell of ['pwsh', 'powershell']) {
      // The two collections inside the command, while it still holds the reader, move the reader
      // into the oldest generation, as reading a long transcript does; only a full collection
      // frees it after that, and an idle shell runs none on its own.
      const cmd = `foreach ($l in [IO.File]::ReadLines('${f}')) { if ($l.Contains('here')) { 'found'; break } }; [GC]::Collect(); [GC]::Collect(); try { $s = [IO.File]::Open('${f}', 'Append', 'Write', 'ReadWrite'); $s.Dispose(); 'not held' } catch { 'held during the command' }`;
      const r = await p.run({ shell, command: cmd });
      check(shell + ': control: inside the command, the reader the loop left open still holds the file', norm(outputOf(r.text)) === 'found\nheld during the command', r.text);
      const a = append();
      check(shell + ': as soon as the reply comes, another program can write to the file', a === 'works', 'append: ' + a);
    }
    await p.close();
  }

  console.log('\n' + (failures === 0 ? `All ${checks} checks passed.` : `${failures} of ${checks} check(s) FAILED:\n  ` + failed.join('\n  ')));
  process.exitCode = failures === 0 ? 0 : 1;
})().catch((e) => {
  check('the test itself ran to its end', false, 'it stopped with ' + (e && e.stack ? e.stack.split('\n').slice(0, 3).join(' | ') : e));
  process.exitCode = 1;
  // A petal left open keeps this process alive, so the run could never end.
  for (const p of petals) { try { p.proc.kill(); } catch (err) { /* already gone */ } }
});
