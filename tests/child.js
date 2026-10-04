// A program for petal's tests to run inside its shells.
//   print <hex>         writes those bytes to standard output
//   exit <code>         exits with that code
//   stdin               reports what standard input gives within 3 s
//   sleep <pid-file>    writes its process id to the file, then sleeps two minutes
//   env <name>...       prints NAME=value (or NAME unset) for each name
//   late <ms> <hex>     writes those bytes to standard output after that many milliseconds
//   relay <exe> <arg>...  runs the program with this process's standard streams, as its parent
'use strict';
const fs = require('fs');
const [mode, ...rest] = process.argv.slice(2);
if (mode === 'print') {
  process.stdout.write(Buffer.from(rest[0], 'hex'));
} else if (mode === 'exit') {
  process.exit(Number(rest[0]));
} else if (mode === 'stdin') {
  let got = Buffer.alloc(0);
  const done = (how) => { process.stdout.write(`stdin ${how} after ${got.length} bytes\n`); process.exit(0); };
  process.stdin.on('data', (d) => { got = Buffer.concat([got, d]); });
  process.stdin.on('end', () => done('ended'));
  process.stdin.on('error', () => done('failed'));
  setTimeout(() => done('still open'), 3000);
} else if (mode === 'sleep') {
  fs.writeFileSync(rest[0], String(process.pid));
  setTimeout(() => {}, 120000);
} else if (mode === 'env') {
  for (const name of rest) {
    const key = Object.keys(process.env).find((k) => k.toLowerCase() === name.toLowerCase());
    process.stdout.write(key === undefined ? `${name} unset\n` : `${name}=${process.env[key]}\n`);
  }
} else if (mode === 'relay') {
  const program = require('child_process').spawn(rest[0], rest.slice(1), { stdio: 'inherit', windowsHide: true });
  program.on('exit', (code) => process.exit(code === null ? 1 : code));
} else if (mode === 'late') {
  setTimeout(() => process.stdout.write(Buffer.from(rest[1], 'hex')), Number(rest[0]));
} else {
  process.stderr.write('unknown mode ' + mode + '\n');
  process.exit(2);
}
