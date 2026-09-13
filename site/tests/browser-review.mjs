import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { startServer } from './serve.mjs';

const output = fileURLToPath(new URL('../../build/site-review/', import.meta.url));
await mkdir(output, { recursive: true });
const local = process.argv[2] ? null : await startServer();
const url = process.argv[2] || local.url;
const profile = await mkdtemp(join(tmpdir(), 'mirrorme-site-review-'));
const edge = join(process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe');
const browser = spawn(edge, ['--headless=new', '--no-first-run', '--disable-background-networking', '--disable-extensions', '--disable-sync', '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { windowsHide: true, stdio: 'ignore' });
browser.on('error', error => { console.error(error); });
let socket;
const results = [];
const exceptions = [];
const failures = [];
const requests = [];
const loaded = new Set();
const pending = new Map();
let id = 0;
async function until(condition, name, timeout = 15000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) { if (await condition()) return; await delay(40); }
  throw new Error(`Timed out: ${name}`);
}
try {
  let port;
  await until(async () => {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; return Boolean(port); }
    catch (error) { if (error.code !== 'ENOENT') throw error; return false; }
  }, 'launch isolated Edge');
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const request = pending.get(message.id);
      clearTimeout(request.timer);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message)); else request.resolve(message.result);
    }
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails.text);
    if (message.method === 'Network.loadingFailed' && !message.params.canceled) failures.push(message.params.errorText);
    if (message.method === 'Network.responseReceived' && message.params.response.status >= 400) failures.push(`${message.params.response.status} ${message.params.response.url}`);
    if (message.method === 'Network.requestWillBeSent' && /^https?:/.test(message.params.request.url)) requests.push(message.params.request.url);
    if (message.method === 'Page.lifecycleEvent' && message.params.name === 'DOMContentLoaded') loaded.add(message.params.loaderId);
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const key = ++id;
    const timer = setTimeout(() => { pending.delete(key); reject(new Error(`Timed out: ${method}`)); }, 15000);
    pending.set(key, { resolve, reject, timer });
    socket.send(JSON.stringify({ id: key, method, params }));
  });
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  await send('Runtime.enable');
  await send('Page.enable');
  await send('Network.enable');
  await send('Page.setLifecycleEventsEnabled', { enabled: true });
  async function open(width, dark = false, reduced = false) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: width < 700 ? 1000 : 1080, deviceScaleFactor: 1, mobile: false });
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: dark ? 'dark' : 'light' }, { name: 'prefers-reduced-motion', value: reduced ? 'reduce' : 'no-preference' }] });
    const result = await send('Page.navigate', { url });
    await until(() => loaded.has(result.loaderId), 'load requested document');
    await until(() => evaluate('document.querySelector("#demo")?.dataset.ready === "true"'), 'initialize demo');
  }
  const click = selector => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  async function inspect(name) {
    const data = await evaluate(`(() => {
      const ids = [...document.querySelectorAll('[id]')].map(e => e.id);
      return {
        overflow: document.documentElement.scrollWidth > innerWidth,
        clipped: [...document.querySelectorAll('button, textarea, .demo, .desktop, .phone')].filter(e => e.getClientRects().length && (e.getBoundingClientRect().left < -1 || e.getBoundingClientRect().right > innerWidth + 1)).map(e => e.id || e.className),
        duplicates: ids.filter((id, i) => ids.indexOf(id) !== i),
        missingLabels: [...document.querySelectorAll('button, textarea')].filter(e => !e.textContent.trim() && !e.getAttribute('aria-label') && !e.labels?.length).map(e => e.id),
        phase: document.querySelector('#demo').dataset.phase
      };
    })()`);
    assert.equal(data.overflow, false, `${name}: page overflow`);
    assert.deepEqual(data.clipped, [], `${name}: clipped controls`);
    assert.deepEqual(data.duplicates, [], `${name}: duplicate IDs`);
    assert.deepEqual(data.missingLabels, [], `${name}: unlabeled controls`);
    results.push({ name, ...data });
  }
  async function screenshot(name) {
    await delay(350);
    const image = await send('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(output, `${name}.png`), Buffer.from(image.data, 'base64'));
  }
  for (const width of [1440, 1024, 768, 390, 320]) {
    for (const dark of [false, true]) {
      const prefix = `${width}-${dark ? 'dark' : 'light'}`;
      await open(width, dark);
      await inspect(`${prefix}-ready`);
      await click('#connect');
      await until(() => evaluate('document.querySelector("#demo").dataset.phase === "mirroring"'), 'connect example');
      assert.equal(await evaluate('document.querySelector("#mirrored-screen").hidden'), false);
      await inspect(`${prefix}-mirroring`);
      if (width === 1440 || width === 390) await screenshot(prefix);
      await click('#rotate');
      await delay(350);
      await inspect(`${prefix}-landscape`);
      await click('[data-content="notes"][type="button"]');
      await evaluate(`(() => { const e = document.querySelector('#demo-note'); e.focus(); e.value = '<script>not markup</script>\\nMy example'; e.dispatchEvent(new Event('input', { bubbles: true })); })()`);
      assert.deepEqual(await evaluate('[...document.querySelectorAll("[data-note]")].map(e => e.textContent)'), ['<script>not markup</script>\nMy example', '<script>not markup</script>\nMy example']);
      assert.equal(await evaluate('document.activeElement.id'), 'demo-note');
      await inspect(`${prefix}-edited-note`);
    }
  }
  await open(1440, false, true);
  assert.equal(await evaluate('document.querySelector("#demo").dataset.playing'), 'false');
  assert.equal(await evaluate('getComputedStyle(document.querySelector(".photo-image svg")).animationName'), 'none');
  await click('[data-content="clock"][type="button"]');
  const frozen = await evaluate('document.querySelector("[data-clock]").textContent');
  await delay(1100);
  assert.equal(await evaluate('document.querySelector("[data-clock]").textContent'), frozen);
  await click('#motion');
  await delay(1100);
  assert.notEqual(await evaluate('document.querySelector("[data-clock]").textContent'), frozen);
  await click('#motion');
  await click('#connect');
  await click('#connect');
  await delay(1200);
  assert.equal(await evaluate('document.querySelector("#demo").dataset.phase'), 'idle');
  await click('#reset');
  assert.equal(await evaluate('document.querySelector("#demo-note").value.startsWith("Make something")'), true);
  await click('#theme');
  assert.equal(await evaluate('document.documentElement.dataset.mode'), 'dark');
  await evaluate('document.querySelector("#connect").focus()');
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await until(() => evaluate('document.querySelector("#demo").dataset.phase === "mirroring"'), 'connect using keyboard');
  await inspect('keyboard-reduced-motion-cancellation');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'forced-colors', value: 'active' }] });
  await inspect('high-contrast');
  assert.deepEqual(exceptions, [], 'no browser exceptions');
  assert.deepEqual(failures, [], 'no failed assets or blocked scripts');
  assert.deepEqual(requests.filter(request => new URL(request).origin !== new URL(url).origin), [], 'no third-party runtime requests');
  await writeFile(join(output, 'results.json'), JSON.stringify({ url, scenarios: results, exceptions, failures }, null, 2));
  console.log(`Passed ${results.length} website scenarios; real keyboard, notes, rotation, motion, cancellation, and project-base assets verified.`);
  console.log(`Screenshots: ${output}`);
} finally {
  for (const request of pending.values()) clearTimeout(request.timer);
  socket?.close();
  browser.kill();
  if (browser.exitCode === null) await Promise.race([once(browser, 'exit'), delay(5000)]);
  if (local) await new Promise(resolve => local.server.close(resolve));
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
}
