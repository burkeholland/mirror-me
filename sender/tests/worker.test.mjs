import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// These process tests never request capture. On Linux, run the managed worker
// against the installed runtime to cover its pipes and real mDNS discovery.
const root = resolve(import.meta.dirname, '../..');
const temporary = await mkdtemp(join(tmpdir(), 'mirrorme-sender-test-'));
after(() => rm(temporary, { recursive: true, force: true }));
let command = join(root, 'build/bin/sender/MirrorMe.Sender.exe');
let args = [];
if (process.platform !== 'win32') {
  const runtimes = execFileSync('dotnet', ['--list-runtimes'], { encoding: 'utf8' });
  const version = [...runtimes.matchAll(/^Microsoft\.NETCore\.App (\S+)/gm)].at(-1)?.[1];
  assert.ok(version, 'An installed .NET runtime is required.');
  const config = join(temporary, 'runtimeconfig.json');
  await writeFile(config, JSON.stringify({ runtimeOptions: {
    tfm: `net${version.split('.')[0]}.0`, framework: { name: 'Microsoft.NETCore.App', version },
  } }));
  command = 'dotnet';
  args = ['exec', '--runtimeconfig', config,
    join(root, 'sender/bin/Release/net8.0-windows10.0.22621.0/win-x64/MirrorMe.Sender.dll')];
}

function worker(t, input, stopAfter) {
  return new Promise((resolveResult, reject) => {
    const child = spawn(command, args, { cwd: root, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
    t.after(() => { if (child.exitCode === null) child.kill(); });
    let stdout = '', stderr = '';
    const timeout = setTimeout(() => { child.kill(); reject(new Error(`Worker timeout: ${stderr}`)); }, 15000);
    const stop = stopAfter === undefined ? null : setTimeout(() => {
      child.stdin.write('{"protocol":1,"commandName":"stop"}\n');
    }, stopAfter);
    child.on('error', reject);
    child.stdout.on('data', data => { stdout += data; });
    child.stderr.on('data', data => { stderr += data; });
    child.on('close', code => {
      clearTimeout(timeout);
      if (stop) clearTimeout(stop);
      try {
        resolveResult({ code, events: stdout.trim() ? stdout.trim().split('\n').map(line => JSON.parse(line)) : [], stderr });
      } catch (error) { reject(error); }
    });
    child.stdin.on('error', error => { if (error.code !== 'EPIPE') reject(error); });
    if (input === null) child.stdin.end();
    else child.stdin.write(input + '\n');
  });
}

test('EOF before a command exits without capturing or claiming a connection', async t => {
  const result = await worker(t, null);
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.events, []);
});

test('invalid protocol reports a typed error while input remains open', async t => {
  const result = await worker(t, '{"protocol":999,"commandName":"discover"}');
  assert.equal(result.code, 1, result.stderr);
  assert.equal(result.events[0].status, 'error');
  assert.match(result.events[0].error, /Incompatible sender protocol/);
});

test('a blocked input reader cannot prevent command processing', async t => {
  const result = await worker(t, '{"protocol":1,"commandName":"unsupported"}');
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.events[0].error, /Unsupported sender command/);
});

test('discovery finishes while waiting for a subsequent command', async t => {
  const result = await worker(t, '{"protocol":1,"commandName":"discover"}');
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.equal(result.events.length, 1);
  assert.equal(result.events[0].status, 'ready');
  assert.ok(Array.isArray(result.events[0].targets));
  assert.ok(result.events[0].targets.length <= 64);
});

test('Stop interrupts discovery without starting capture', async t => {
  const result = await worker(t, '{"protocol":1,"commandName":"discover"}', 500);
  assert.equal(result.code, 0, JSON.stringify(result));
  assert.deepEqual(result.events.map(event => event.status), ['stopped']);
});
