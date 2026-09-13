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
const requestTypes = [];
const loaded = new Set();
const contexts = new Map();
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
    if (message.method === 'Network.requestWillBeSent' && /^https?:/.test(message.params.request.url)) {
      requests.push(message.params.request.url);
      requestTypes.push(message.params.type);
    }
    if (message.method === 'Page.lifecycleEvent' && message.params.name === 'DOMContentLoaded') loaded.add(message.params.loaderId);
    if (message.method === 'Runtime.executionContextCreated' && message.params.context.auxData?.isDefault) {
      contexts.set(message.params.context.auxData.frameId, message.params.context.id);
    }
    if (message.method === 'Runtime.executionContextsCleared') contexts.clear();
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const key = ++id;
    const timer = setTimeout(() => { pending.delete(key); reject(new Error(`Timed out: ${method}`)); }, 15000);
    pending.set(key, { resolve, reject, timer });
    socket.send(JSON.stringify({ id: key, method, params }));
  });
  const evaluate = async (expression, contextId) => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true, ...(contextId ? { contextId } : {}) });
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
    await until(() => evaluate('document.querySelector("#demo")?.dataset.ready === "true"'), 'initialize the shared app');
  }
  const click = selector => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const app = expression => evaluate(`(() => {
    const document = globalThis.document.querySelector('#app-preview').contentDocument;
    const window = document.defaultView;
    const getComputedStyle = window.getComputedStyle.bind(window);
    return (${expression});
  })()`);
  const appClick = selector => app(`document.querySelector(${JSON.stringify(selector)}).click()`);
  const appUntil = (expression, name) => until(() => app(expression), name);
  const field = (name, value) => app(`(() => {
    const e = document.querySelector('#field-' + ${JSON.stringify(name)});
    e.focus();
    if (e.type === 'checkbox') e.checked = ${JSON.stringify(value)}; else e.value = ${JSON.stringify(value)};
    e.dispatchEvent(new window.Event(e.tagName === 'SELECT' || e.type === 'checkbox' ? 'change' : 'input', { bubbles: true }));
  })()`);
  async function key(name, code, virtual, modifiers = 0, text) {
    await send('Input.dispatchKeyEvent', { type: 'keyDown', key: name, code, windowsVirtualKeyCode: virtual, modifiers, ...(text ? { text } : {}) });
    await send('Input.dispatchKeyEvent', { type: 'keyUp', key: name, code, windowsVirtualKeyCode: virtual, modifiers });
  }
  const layout = `(() => {
    const ids = [...document.querySelectorAll('[id]')].map(e => e.id);
    return {
      overflow: document.documentElement.scrollWidth > window.innerWidth,
      clipped: [...document.querySelectorAll('button, input, select, textarea, iframe')].filter(e => e.getClientRects().length && !e.closest('[hidden]') && (e.getBoundingClientRect().left < -1 || e.getBoundingClientRect().right > window.innerWidth + 1)).map(e => e.id || e.className),
      duplicates: ids.filter((id, i) => ids.indexOf(id) !== i),
      missingLabels: [...document.querySelectorAll('button, input, select, textarea')].filter(e => !e.textContent.trim() && !e.getAttribute('aria-label') && !e.getAttribute('aria-labelledby') && !e.labels?.length).map(e => e.id),
      brokenReferences: [...document.querySelectorAll('[aria-controls], [aria-labelledby], [aria-describedby]')].flatMap(e => ['aria-controls', 'aria-labelledby', 'aria-describedby'].flatMap(attr => (e.getAttribute(attr) || '').split(' ').filter(id => id && !document.getElementById(id))))
    };
  })()`;
  async function inspect(name) {
    const data = { page: await evaluate(layout), app: await app(layout) };
    for (const [surface, value] of Object.entries(data)) {
      assert.equal(value.overflow, false, `${name} ${surface}: overflow`);
      assert.deepEqual(value.clipped, [], `${name} ${surface}: clipped controls`);
      assert.deepEqual(value.duplicates, [], `${name} ${surface}: duplicate IDs`);
      assert.deepEqual(value.missingLabels, [], `${name} ${surface}: unlabeled controls`);
      assert.deepEqual(value.brokenReferences, [], `${name} ${surface}: broken ARIA references`);
    }
    assert.equal(await evaluate('getComputedStyle(document.querySelector("#app-preview")).transform'), 'none', 'The real UI is not shrunk with CSS transforms');
    results.push({ name, ...data });
  }
  async function screenshot(name) {
    await delay(350);
    const image = await send('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(output, `${name}.png`), Buffer.from(image.data, 'base64'));
  }
  try {
    for (const width of [1440, 1024, 768, 390, 320]) {
      for (const dark of [false, true]) {
        const prefix = `${width}-${dark ? 'dark' : 'light'}`;
        await open(width, dark);
        assert.equal(await evaluate('document.querySelector("#demo").dataset.phase'), 'mirroring');
        assert.equal(await evaluate('document.querySelector("#video-window").hidden'), false);
        assert.equal(await evaluate('document.querySelector("#connect")'), null);
        assert.equal(await evaluate('document.querySelectorAll(".sample").length'), 1);
        assert.equal(await evaluate('document.querySelector(".sample").classList.contains("photos")'), true);
        assert.equal(await evaluate('document.querySelector("[data-content], #demo-note, .note-editor, .notes, .clock")'), null);
        assert.equal(await evaluate('document.querySelector("#headline").innerText'), 'Mirror your iPhone\nto Windows.');
        assert.ok(await evaluate(`document.querySelector('#demo').getBoundingClientRect().top < ${width < 700 ? 600 : 400}`), 'the app preview appears near the top of the page');
        assert.match(await app('document.querySelector("#connection-title").textContent'), /mirroring/i);
        assert.equal(await app('getComputedStyle(document.querySelector("#page-title")).fontSize'), '26px');
        assert.equal(await app('document.querySelector("#nav-settings").textContent.includes("Settings")'), true);
        await inspect(`${prefix}-immediately-interactive`);
        if (width === 1440 || width === 390) {
          await screenshot(`${prefix}-page`);
          await evaluate('document.querySelector("#demo").scrollIntoView()');
          await screenshot(prefix);
        }
        await appClick('#nav-settings');
        assert.equal(await app('document.querySelector("#field-deviceName").value'), 'Studio PC');
        await field('deviceName', 'Example desk');
        assert.equal(await app('document.activeElement.id'), 'field-deviceName');
        assert.equal(await app('document.querySelector("[data-save-bar]").hidden'), false);
        await appClick('#action-save-settings');
        await appUntil('document.querySelector("[data-save-bar]").hidden', 'save real Settings draft');
        await field('deviceName', 'Unsaved example');
        await appClick('#nav-home');
        await appUntil('Boolean(document.querySelector("dialog[open]"))', 'unsaved changes dialog');
        await appClick('#action-discard-and-leave');
        await appUntil('document.querySelector("#nav-home").getAttribute("aria-current") === "page"', 'discard and leave');
        assert.equal(await app('document.querySelector(".receiver-name strong").textContent'), 'Example desk');
        await appClick('#nav-settings');
        await appClick('#tab-picture');
        await field('resolution', '1920x1080');
        await appClick('#action-revert-settings');
        assert.equal(await app('document.querySelector("#field-resolution").value'), 'auto');
        await inspect(`${prefix}-real-settings`);
        if (width === 1440) await screenshot(`${prefix}-settings`);
        await click('#rotate');
        assert.equal(await evaluate('document.querySelector("#rotate").getAttribute("aria-pressed")'), 'true');
        await inspect(`${prefix}-separate-landscape-video`);
        const ratio = await evaluate('(() => { const r = document.querySelector("#mirrored-screen").getBoundingClientRect(); return r.width / r.height; })()');
        assert.ok(Math.abs(ratio - 2) < 0.01, 'the photo rotates to landscape');
        await click('#motion');
        assert.equal(await evaluate('getComputedStyle(document.querySelector(".photo-image svg")).animationPlayState'), 'paused');
        await click('#motion');
        assert.equal(await evaluate('getComputedStyle(document.querySelector(".photo-image svg")).animationPlayState'), 'running');
        await inspect(`${prefix}-photo-motion`);
      }
    }
    await open(1440, false, true);
    assert.equal(await evaluate('document.querySelector("#motion").checked'), false);
    assert.equal(await evaluate('getComputedStyle(document.querySelector(".photo-image svg")).animationName'), 'none');
    await click('#motion');
    assert.equal(await evaluate('getComputedStyle(document.querySelector(".photo-image svg")).animationName'), 'none', 'the system reduced-motion preference still takes priority');
    await click('#motion');

    await appClick('#window-minimise');
    await until(() => evaluate('document.querySelector("#app-preview").hidden'), 'minimize app');
    assert.equal(await evaluate('document.querySelector("#video-window").hidden'), false);
    await click('#restore-app');
    await appClick('#window-hide');
    await until(() => evaluate('document.querySelector("#app-preview").hidden'), 'hide app to example tray');
    assert.equal(await evaluate('document.querySelector("#demo").dataset.phase'), 'mirroring');
    await click('#restore-app');
    await appClick('#window-maximise');
    await until(() => evaluate('document.querySelector("#preview-desk").dataset.appExpanded === "true"'), 'maximize app');
    await appUntil('document.querySelector("#window-maximise").getAttribute("aria-label") === "Restore"', 'real restore caption');
    await inspect('expanded-real-app');
    await appClick('#window-maximise');
    await until(() => evaluate('document.querySelector("#preview-desk").dataset.appExpanded === "false"'), 'restore app');
    await click('#minimise-video');
    assert.equal(await evaluate('document.querySelector("#video-window").hidden'), true);
    await appClick('#action-show-mirrored-screen');
    await until(() => evaluate('document.activeElement.id === "video-window"'), 'Show screen focuses separate video');
    assert.equal(await evaluate('document.querySelector("#video-window").hidden'), false);
    await click('#maximise-video');
    await inspect('expanded-separate-video');
    await click('#maximise-video');
    await click('#close-video');
    await appUntil('document.querySelector("[data-receiver-label]").textContent !== "Mirroring"', 'close video reaches app');
    assert.equal(await evaluate('document.querySelector("#video-window").hidden'), true);
    await click('#restore-video');
    await appUntil('Boolean(document.querySelector("#action-show-mirrored-screen"))', 'reconnect example');
    await appClick('#action-stop-mirroring');
    await until(() => evaluate('document.querySelector("#demo").dataset.phase === "stopped"'), 'real Stop stops the example');
    await appClick('#action-start-mirroring');
    await until(() => evaluate('document.querySelector("#demo").dataset.phase === "advertising"'), 'real Start starts receiving, not fake video');
    await click('#restore-video');
    await appUntil('Boolean(document.querySelector("#action-show-mirrored-screen"))', 'reconnect from ready');
    await inspect('app-and-video-lifecycle');

    await app('document.querySelector("#nav-home").focus()');
    await key(',', 'Comma', 188, 2);
    await appUntil('Boolean(document.querySelector("#tab-app"))', 'Ctrl+comma opens real Settings');
    await field('deviceName', 'Keyboard example');
    await key('s', 'KeyS', 83, 2);
    await appUntil('document.querySelector("[data-save-bar]").hidden', 'Ctrl+S saves real Settings');
    await app('document.querySelector("#tab-connection").focus()');
    await key('ArrowRight', 'ArrowRight', 39);
    assert.equal(await app('document.querySelector("#tab-picture").getAttribute("aria-selected")'), 'true');
    await key('F1', 'F1', 112);
    await appUntil('Boolean(document.querySelector("dialog[open]"))', 'F1 opens real connection guide');
    assert.match(await app('document.querySelector("dialog").textContent'), /Keyboard example/);
    await key('Escape', 'Escape', 27);
    await appUntil('!document.querySelector("dialog")', 'Escape closes connection guide');
    await appClick('#tab-app');
    await field('theme', 'dark');
    assert.equal(await app('document.documentElement.dataset.mode'), 'dark');
    await appClick('#action-revert-settings');
    assert.equal(await app('document.documentElement.dataset.mode'), 'light');
    await field('theme', 'dark');
    await appClick('#nav-home');
    await appClick('#action-save-and-leave');
    await appUntil('Boolean(document.querySelector("#connection-title"))', 'save theme and navigate');
    assert.equal(await app('document.documentElement.dataset.mode'), 'dark');
    await appClick('#copy-home-name');
    await appUntil('document.querySelector("[data-app-error]")?.textContent.includes("browser preview")', 'clipboard explains preview boundary');
    await inspect('keyboard-dialogs-themes-and-native-limit');
    await click('#reset');
    await appUntil('!document.querySelector("[data-app-error]")', 'reset clears error');
    assert.equal(await app('document.querySelector(".receiver-name strong").textContent'), 'Studio PC');
    assert.equal(await evaluate('document.querySelector("#rotate").getAttribute("aria-pressed")'), 'false');
    assert.equal(await evaluate('document.querySelector("#motion").checked'), false);
    await click('#theme');
    await appUntil('document.documentElement.dataset.mode === "dark"', 'page theme synchronizes app');
    await appClick('#nav-settings');
    await appClick('#tab-connection');
    await field('requirePin', true);
    await appClick('#action-save-settings');
    await appUntil('Boolean(document.querySelector("output.pin-code"))', 'real pairing setting');
    assert.equal(await app('document.querySelector("output.pin-code").textContent'), '2468');
    await appClick('#action-regenerate-pin');
    await appUntil('document.querySelector("output.pin-code").textContent === "1357"', 'new example pairing code');
    await appClick('#nav-about');
    await app('document.querySelector("#disclosure-support-files").click()');
    await appClick('#action-open-settings-folder');
    await appUntil('document.querySelector("[data-app-error]")?.textContent.includes("browser preview")', 'folder action explains boundary');
    await appClick('#action-quit');
    await until(() => evaluate('document.querySelector("#app-preview").hidden && document.querySelector("#demo").dataset.phase === "stopped"'), 'quit example');
    await click('#reset');
    await appUntil('Boolean(document.querySelector("#connection-title"))', 'reset restores app');
    await inspect('pairing-and-reset');
    assert.equal(await evaluate('localStorage.length + sessionStorage.length'), 0, 'no persistent browser settings');
    assert.deepEqual(await evaluate('indexedDB.databases()'), [], 'no browser database');

    await evaluate(`window.postMessage({ channel: 'mirrorme-website-preview', type: 'status', status: 'stopped' }, location.origin)`);
    const tree = await send('Page.getFrameTree');
    const child = tree.frameTree.childFrames.find(child => child.frame.url.includes('/preview/index.html'));
    const context = contexts.get(child.frame.id);
    assert.ok(context, 'find the iframe execution context');
    await evaluate(`window.postMessage({ channel: 'mirrorme-website-preview', type: 'close-video' }, location.origin)`, context);
    await delay(80);
    assert.equal(await evaluate('document.querySelector("#demo").dataset.phase'), 'mirroring', 'ignore messages from the wrong source');
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'forced-colors', value: 'active' }] });
    await inspect('high-contrast');
    assert.deepEqual(exceptions, [], 'no browser exceptions');
    assert.deepEqual(failures, [], 'no failed assets or blocked scripts');
    assert.deepEqual(requests.filter(request => new URL(request).origin !== new URL(url).origin), [], 'no third-party runtime requests');
    assert.deepEqual(requestTypes.filter(type => ['Fetch', 'XHR', 'WebSocket'].includes(type)), [], 'only static assets are requested');
  } catch (error) {
    await screenshot('failure');
    throw error;
  }
  await writeFile(join(output, 'results.json'), JSON.stringify({ url, scenarios: results, exceptions, failures }, null, 2));
  console.log(`Passed ${results.length} website scenarios; shared app, immediate video, real Settings, separate windows, keyboard, native boundaries, and project-base assets verified.`);
  console.log(`Screenshots: ${output}`);
} finally {
  for (const request of pending.values()) clearTimeout(request.timer);
  socket?.close();
  browser.kill();
  if (browser.exitCode === null) await Promise.race([once(browser, 'exit'), delay(5000)]);
  if (local) await new Promise(resolve => local.server.close(resolve));
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 250 });
}
