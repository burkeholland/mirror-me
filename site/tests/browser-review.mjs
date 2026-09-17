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
let launchError;
browser.on('error', error => { launchError = error; });
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
  while (Date.now() < end) {
    if (launchError) throw launchError;
    if (await condition()) return;
    await delay(40);
  }
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
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    if (message.method === 'Network.loadingFailed' && !message.params.canceled) failures.push(message.params.errorText);
    if (message.method === 'Network.responseReceived' && message.params.response.status >= 400) failures.push(`${message.params.response.status} ${message.params.response.url}`);
    if (message.method === 'Network.requestWillBeSent' && /^https?:/.test(message.params.request.url)) {
      requests.push({ url: message.params.request.url, type: message.params.type });
    }
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
    await imagesReady();
  }
  async function imagesReady() {
    await until(() => evaluate(`[...document.images].filter(image => image.getClientRects().length).every(image => image.complete && image.naturalWidth > 0)`), 'load visible static images');
  }
  async function inspect(name) {
    const data = await evaluate(`(() => {
      const visible = e => e.getClientRects().length > 0;
      const preview = document.querySelector('#demo');
      const image = [...preview.querySelectorAll('.app-screenshot')].find(visible);
      const ids = [...document.querySelectorAll('[id]')].map(e => e.id);
      const desk = document.querySelector('.preview-desk');
      const deskStyle = getComputedStyle(desk);
      const appBox = document.querySelector('.app-frame').getBoundingClientRect();
      const phone = document.querySelector('.video-panel');
      const phoneBox = document.querySelector('.video-window').getBoundingClientRect();
      const screenBox = document.querySelector('.mirrored-screen').getBoundingClientRect();
      return {
        width: innerWidth,
        phoneVisible: visible(phone),
        previewTopDifference: Math.abs(appBox.top - phoneBox.top),
        previewGap: phoneBox.left - appBox.right,
        phoneRatio: visible(phone) ? screenBox.width / screenBox.height : null,
        fullWidthDifference: desk.clientWidth - parseFloat(deskStyle.paddingLeft) - parseFloat(deskStyle.paddingRight) - appBox.width,
        overflow: document.documentElement.scrollWidth > innerWidth,
        clipped: [...document.querySelectorAll('button, img, h1')].filter(visible).filter(e => {
          const box = e.getBoundingClientRect(); return box.left < -1 || box.right > innerWidth + 1;
        }).map(e => e.id || e.className),
        duplicates: ids.filter((id, i) => ids.indexOf(id) !== i),
        controls: preview.querySelectorAll('iframe, button, input, select, textarea, a, [tabindex]').length,
        removed: document.querySelectorAll('.demo-controls, .details-section, #rotate, #motion, #reset').length,
        image: image?.getAttribute('src'),
        ratio: image?.getBoundingClientRect().width / image?.getBoundingClientRect().height,
        alt: image?.alt,
        mode: document.documentElement.dataset.mode,
        text: document.body.textContent,
        motion: getComputedStyle(document.querySelector('.photo-image svg')).animationName,
      };
    })()`);
    assert.equal(data.overflow, false, `${name}: overflow`);
    assert.deepEqual(data.clipped, [], `${name}: clipped content`);
    assert.deepEqual(data.duplicates, [], `${name}: duplicate IDs`);
    assert.equal(data.controls, 0, `${name}: the preview must be static`);
    assert.equal(data.removed, 0, `${name}: removed sections remain absent`);
    assert.equal(data.image, `./assets/app-${data.mode}.png`);
    assert.ok(Math.abs(data.ratio - 1040 / 760) < 0.01, `${name}: screenshot proportions`);
    assert.ok(data.alt.length > 0);
    assert.doesNotMatch(data.text, /ux\s*play|About this preview|Sample image/i);
    assert.match(data.text, /17\.9 MB executable/);
    assert.match(data.text, /Download for Windows/);
    assert.match(data.text, /Source, licenses & checksums/);
    assert.equal(await evaluate("document.querySelector('.download').getAttribute('href')"),
      'https://github.com/burkeholland/mirror-me/releases/download/v0.2.4-preview.1/MirrorMe-0.2.4-windows-x64.zip');
    assert.doesNotMatch(data.text, /Older v0\.1\.0|Download Windows preview|separate receiver setup/);
    assert.equal(data.motion, 'none');
    if (data.width >= 768) {
      assert.equal(data.phoneVisible, true, `${name}: show the iPhone on tablet and desktop`);
      assert.ok(data.previewTopDifference < 1, `${name}: both windows must share a row`);
      assert.ok(data.previewGap >= 12, `${name}: keep a gap between the windows`);
      assert.ok(Math.abs(data.phoneRatio - 0.5) < 0.01, `${name}: preserve the iPhone screen proportions`);
    } else {
      assert.equal(data.phoneVisible, false, `${name}: hide the iPhone on small screens`);
      assert.ok(Math.abs(data.fullWidthDifference) < 1, `${name}: app uses the full preview width`);
    }
    delete data.text;
    results.push({ name, ...data });
  }
  async function screenshot(name) {
    const image = await send('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(output, `${name}.png`), Buffer.from(image.data, 'base64'));
  }
  try {
    for (const width of [1920, 1440, 1280, 1024, 800, 768, 767, 700, 390, 320]) {
      for (const dark of [false, true]) {
        const name = `${width}-${dark ? 'dark' : 'light'}`;
        await open(width, dark);
        assert.equal(await evaluate('document.documentElement.dataset.mode'), dark ? 'dark' : 'light');
        await inspect(name);
        await evaluate('document.querySelector(".app-screenshot").click()');
        assert.equal(await evaluate('location.href'), url, 'clicking the screenshot does not launch a demo');
        if ([1440, 768, 767, 390].includes(width)) await screenshot(`${name}-page`);
      }
    }
    await open(1440, false, true);
    await send('Page.bringToFront');
    await evaluate('document.querySelector("#theme").focus()');
    assert.equal(await evaluate('document.activeElement.id'), 'theme', 'theme switch receives keyboard focus');
    for (const type of ['keyDown', 'keyUp']) {
      await send('Input.dispatchKeyEvent', { type, key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, ...(type === 'keyDown' ? { text: '\r' } : {}) });
    }
    await imagesReady();
    assert.equal(await evaluate('document.documentElement.dataset.mode'), 'dark');
    assert.equal(await evaluate('document.querySelector("#theme").getAttribute("aria-label")'), 'Use light theme');
    await inspect('keyboard-theme-and-reduced-motion');
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await delay(80);
    assert.equal(await evaluate('document.documentElement.dataset.mode'), 'dark', 'explicit theme choice wins over system changes');
    const tree = await send('Page.getFrameTree');
    assert.equal(tree.frameTree.childFrames?.length || 0, 0, 'no embedded app is loaded');
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'forced-colors', value: 'active' }] });
    await inspect('high-contrast');
    await send('Emulation.setScriptExecutionDisabled', { value: true });
    await open(390);
    assert.equal(await evaluate('document.querySelector("#theme").hidden'), true);
    await inspect('static-content-without-javascript');
    assert.deepEqual(exceptions, [], 'no browser exceptions');
    assert.deepEqual(failures, [], 'no failed images or blocked scripts');
    assert.deepEqual(requests.filter(request => new URL(request.url).origin !== new URL(url).origin), [], 'no third-party requests');
    assert.deepEqual(requests.filter(request => ['Fetch', 'XHR', 'WebSocket'].includes(request.type) || new URL(request.url).pathname.includes('/preview/')), [], 'no app runtime or data requests');
  } catch (error) {
    console.error(JSON.stringify({ exceptions, failures, theme: await evaluate('({ mode: document.documentElement.dataset.mode, focus: document.activeElement.id, label: document.querySelector("#theme")?.getAttribute("aria-label") })') }));
    await screenshot('failure');
    throw error;
  }
  await writeFile(join(output, 'results.json'), JSON.stringify({ url, scenarios: results, exceptions, failures }, null, 2));
  console.log(`Passed ${results.length} website scenarios; static screenshots, responsive layouts, themes, keyboard and no-JavaScript use verified.`);
  console.log(`Screenshots: ${output}`);
} finally {
  for (const request of pending.values()) clearTimeout(request.timer);
  socket?.close();
  browser.kill();
  if (browser.exitCode === null) await Promise.race([once(browser, 'exit'), delay(5000)]);
  if (local) await new Promise(resolve => local.server.close(resolve));
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
}
