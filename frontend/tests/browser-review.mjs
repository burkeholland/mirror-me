import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { access, mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { createServer as createHTTPServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { createServer } from 'vite';

// Use the installed Edge engine and existing Node/Vite tools, not a second
// browser dependency. The browser gets a fresh profile and a private port.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const output = resolve(process.argv[2] || join(root, '..', 'build', 'ui-review'));
const candidates = [
  join(process.env['PROGRAMFILES(X86)'] || 'C:\\Program Files (x86)', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
  join(process.env.PROGRAMFILES || 'C:\\Program Files', 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
];
let executable;
for (const candidate of candidates) {
  try { await access(candidate); executable = candidate; break; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
assert.ok(executable, 'Microsoft Edge is required for the Windows UI review.');
await mkdir(output, { recursive: true });
const vite = await createServer({
  root, logLevel: 'error',
  server: { middlewareMode: true, hmr: false, watch: null },
});
const server = createHTTPServer(vite.middlewares);
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const origin = `http://127.0.0.1:${server.address().port}`;
const profile = await mkdtemp(join(tmpdir(), `mirrorme-ui-review-${process.pid}-`));
const browser = spawn(executable, [
  '--headless=new', '--no-first-run', '--no-default-browser-check',
  '--disable-background-networking', '--disable-extensions', '--disable-sync',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank',
], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
let browserErrors = '';
browser.stderr.on('data', data => { browserErrors = (browserErrors + data).slice(-4000); });
let socket;
let send;
const results = [];

async function until(condition, description, timeout = 15000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await condition()) return;
    await delay(50);
  }
  throw new Error(`Timed out: ${description}\n${browserErrors}`);
}

try {
  let port;
  await until(async () => {
    try {
      port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0];
      return Boolean(port);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      return false;
    }
  }, 'start the isolated Edge profile');
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  let id = 0;
  const pending = new Map();
  const loadedDocuments = new Set();
  const errors = [];
  const externalRequests = new Set();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const request = pending.get(message.id);
      if (!request) return;
      clearTimeout(request.timer);
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result);
    }
    if (message.method === 'Runtime.exceptionThrown') {
      errors.push(message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text);
    }
    if (message.method === 'Page.lifecycleEvent' && message.params.name === 'DOMContentLoaded') {
      loadedDocuments.add(message.params.loaderId);
    }
    if (message.method === 'Network.requestWillBeSent') {
      const url = message.params.request.url;
      if (/^https?:/.test(url) && new URL(url).origin !== origin) externalRequests.add(url);
    }
  });
  send = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const requestId = ++id;
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`Browser command timed out: ${method}`));
    }, 15000);
    pending.set(requestId, { resolve: resolveRequest, reject, timer });
    socket.send(JSON.stringify({ id: requestId, method, params }));
  });
  await send('Page.enable');
  await send('Page.setLifecycleEventsEnabled', { enabled: true });
  await send('Runtime.enable');
  await send('Network.enable');
  const evaluate = async expression => {
    const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (response.exceptionDetails) throw new Error(response.exceptionDetails.exception?.description || response.exceptionDetails.text);
    return response.result.value;
  };
  let navigation = 0;
  const open = async (query, width = 1040, height = 760) => {
    errors.length = 0;
    await send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
    const params = new URLSearchParams(query);
    params.set('review', String(++navigation));
    const url = `${origin}/tests/preview.html?${params}`;
    const { loaderId } = await send('Page.navigate', { url });
    await until(() => loadedDocuments.has(loaderId), 'load the new document');
    await until(() => evaluate(`location.href === ${JSON.stringify(url)} && Boolean(window.__mirrorMePreview && !window.__mirrorMePreview.state.loading)`), 'load preview');
    await evaluate('document.fonts.ready.then(() => true)');
    const expectedStatus = params.get('state') || (params.get('onboarding') === '1' && params.get('step') !== '2' ? 'stopped' : 'advertising');
    assert.equal(await evaluate('window.__mirrorMePreview.state.status.status'), expectedStatus, 'the requested receiver state must be on screen');
    assert.equal(await evaluate('window.__mirrorMePreview.state.route'), params.get('route') || 'home', 'the requested route must be on screen');
  };
  const screenshot = async name => {
    await until(() => evaluate(`document.getAnimations().every(animation =>
      animation.effect.getComputedTiming().iterations === Infinity || animation.playState !== 'running')`), 'finish visual transitions', 3000);
    const image = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(join(output, `${name}.png`), Buffer.from(image.data, 'base64'));
  };
  const inspect = () => evaluate(`(() => {
    const visible = element => element.getClientRects().length > 0;
    const ids = [...document.querySelectorAll('[id]')].map(element => element.id);
    const invalidReferences = [...document.querySelectorAll('[aria-labelledby], [aria-describedby], [aria-controls], label[for]')]
      .flatMap(element => ['aria-labelledby', 'aria-describedby', 'aria-controls', 'for']
        .flatMap(attribute => (element.getAttribute(attribute) || '').split(/\\s+/).filter(Boolean)
          .filter(id => !document.getElementById(id)).map(id => element.tagName + ':' + id)));
    const overflow = [...document.querySelectorAll('button, input, select, .setting-row, .mirror-stage, .page-header, .content-dialog')]
      .filter(visible).filter(element => {
        const bounds = element.getBoundingClientRect();
        return bounds.left < -1 || bounds.right > innerWidth + 1;
      }).map(element => element.id || element.className);
    return {
      width: innerWidth, height: innerHeight,
      pageOverflow: document.documentElement.scrollWidth > innerWidth,
      shellOverflow: document.querySelector('.shell').scrollWidth > document.querySelector('.shell').clientWidth,
      duplicateIds: ids.filter((id, index) => ids.indexOf(id) !== index),
      invalidReferences, overflow,
      heading: document.querySelector('#page-title')?.textContent,
      mode: document.documentElement.dataset.mode,
    };
  })()`);
  const check = async name => {
    const result = await inspect();
    assert.equal(result.pageOverflow, false, `${name}: page overflow`);
    assert.equal(result.shellOverflow, false, `${name}: content overflow`);
    assert.deepEqual(result.overflow, [], `${name}: clipped controls`);
    assert.deepEqual(result.duplicateIds, [], `${name}: duplicate IDs`);
    assert.deepEqual(result.invalidReferences, [], `${name}: broken accessible references`);
    assert.deepEqual(errors, [], `${name}: browser exceptions`);
    assert.equal(await evaluate("Boolean(document.querySelector('.connection-details, .diagnostics, [data-action=\"copy-diagnostics\"]'))"), false,
      `${name}: connection details must not appear on any page`);
    const spacing = await evaluate(`(() => {
      const startup = document.querySelector('#panel-app [data-disclosure="windows-startup"]');
      if (!startup?.getClientRects().length) return null;
      const group = startup.nextElementSibling;
      const heading = group.querySelector('h2').getBoundingClientRect();
      const tokens = getComputedStyle(startup);
      return {
        above: heading.top - startup.getBoundingClientRect().bottom,
        below: group.querySelector('.settings-rows').getBoundingClientRect().top - heading.bottom,
        sectionGap: parseFloat(tokens.getPropertyValue('--space-5')),
        headingGap: parseFloat(tokens.getPropertyValue('--space-3')),
      };
    })()`);
    if (spacing) {
      assert.equal(spacing.above, spacing.sectionGap, `${name}: gap above Troubleshooting`);
      assert.equal(spacing.below, spacing.headingGap, `${name}: gap below Troubleshooting`);
    }
    assert.equal(await evaluate(`(() => {
      const marks = [...document.querySelectorAll('.brand-mark svg, .about-mark svg')];
      return marks.length > 0 && marks.every(mark =>
        mark.getAttribute('viewBox') === '0 0 48 48' &&
        mark.querySelector('rect').getAttribute('fill') === '#0369a1' &&
        mark.querySelectorAll('rect').length === 3 &&
        mark.getBoundingClientRect().width === mark.parentElement.getBoundingClientRect().width);
    })()`), true, `${name}: the website brand must render at full size in either theme`);
    results.push({ name, ...result });
  };

  for (const theme of ['light', 'dark']) {
    for (const status of ['stopped', 'starting', 'needs-setup', 'advertising', 'connecting', 'mirroring', 'error']) {
      await open(`state=${status}&theme=${theme}`);
      await check(`${status}-${theme}`);
      assert.equal(await evaluate("Boolean(document.querySelector('.home-hint, .connection-details, .activity-list'))"), false,
        'the main screen must not show the removed diagnostics area');
      assert.match(await evaluate("document.querySelector('.scene-caption').textContent"), /Separate video window/);
      if (status === 'advertising') await screenshot(`ready-${theme}`);
    }
    for (const section of ['connection', 'picture', 'app']) {
      await open(`route=settings&section=${section}&theme=${theme}&pin=1`);
      await check(`settings-${section}-${theme}`);
      if (section === 'app') {
        await evaluate("document.querySelector('[data-disclosure=\"windows-startup\"]').open = true");
        await check(`settings-startup-expanded-${theme}`);
      }
      if (section === 'picture') await screenshot(`settings-${theme}`);
    }
  }
  await open('state=advertising&backend=native');
  await check('native-receiver-ready');
  assert.equal(await evaluate("Boolean(document.querySelector('.connection-details'))"), false);
  await open('route=settings&section=app&backend=native');
  await check('native-troubleshooting-settings');
  assert.equal(await evaluate("Boolean(document.querySelector('[data-action=\"open-logs-folder\"]') && document.querySelector('[data-action=\"copy-logs-path\"]'))"), true);
  assert.equal(await evaluate("document.querySelector('#field-verboseLogging').checked"), false);
  await evaluate(`(() => {
    const input = document.querySelector('#field-verboseLogging');
    input.click(); input.focus();
    window.__mirrorMePreview.emit('log-warning', 'Log storage unavailable');
  })()`);
  assert.equal(await evaluate("document.activeElement.id === 'field-verboseLogging' && document.querySelector('#field-verboseLogging').checked"), true);
  assert.equal(await evaluate("document.querySelector('[data-log-warning]').textContent"), 'Log storage unavailable');
  await evaluate("document.querySelector('[data-action=\"save-settings\"]').click()");
  await until(() => evaluate("window.__mirrorMePreview.state.settings.verboseLogging === true && !window.__mirrorMePreview.state.saving"), 'save verbose logging preference');
  assert.equal(await evaluate("window.__mirrorMePreview.calls.some(call => call[0] === 'start' || call[0] === 'stop')"), false);
  await screenshot('troubleshooting-settings');
  await open('route=about&backend=native');
  await check('native-receiver-help');
  assert.equal(await evaluate("document.body.textContent.includes('GStreamer')"), false);
  for (const [name, query] of [
    ['welcome', 'onboarding=1'],
    ['setup-ready', 'onboarding=1&step=2'],
    ['setup-permission', 'onboarding=1&step=2&state=needs-setup'],
    ['setup-download', 'onboarding=1&step=2&state=needs-setup&download=1'],
    ['download-progress', 'onboarding=1&step=2&state=starting&download=1'],
    ['video-output', 'state=connecting&video=1'],
    ['video-output-recovery', 'state=connecting&video=1&slow=1'],
    ['ready', 'state=advertising&pin=1'],
    ['long-name', `name=${'A long PC name '.repeat(4)}`],
    ['help', 'route=about'],
    ['small-settings', 'route=settings&section=app&theme=dark'],
  ]) {
    await open(query, 760, 560);
    await check(`${name}-minimum-window`);
    if (['welcome', 'ready', 'setup-permission'].includes(name)) await screenshot(`${name}-minimum-window`);
  }
  await open('state=connecting&slow=1&theme=dark');
  await until(() => evaluate('window.__mirrorMePreview.state.connectionSlow'), 'display video-wait recovery');
  await check('slow-connection');
  await screenshot('connection-recovery');
  await open('state=connecting&video=1&slow=1&theme=dark');
  await until(() => evaluate('window.__mirrorMePreview.state.connectionSlow'), 'display video-output recovery');
  assert.equal(await evaluate("document.body.textContent.includes('Windows has not displayed it')"), true);
  await check('slow-video-output');
  await screenshot('video-output-recovery');

  await open('onboarding=1', 760, 560);
  assert.equal(await evaluate("document.querySelector('#setup-continue').getBoundingClientRect().bottom <= innerHeight"), true,
    'the setup Continue button must fit the minimum window without scrolling');
  await evaluate(`(() => {
    const input = document.querySelector('#setup-name');
    input.focus(); input.value = 'Desk PC'; input.dispatchEvent(new Event('input', { bubbles: true }));
  })()`);
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, text: '\r' });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  await until(() => evaluate("window.__mirrorMePreview.state.setupStep === 2 && window.__mirrorMePreview.state.status.status === 'advertising'"), 'complete the first setup step');
  assert.equal(await evaluate("document.querySelector('#action-dismiss-first-run').getBoundingClientRect().bottom <= innerHeight"), true,
    'the setup Done button must fit the minimum window without scrolling');
  await evaluate("document.querySelector('#action-dismiss-first-run').click()");
  await until(() => evaluate('!window.__mirrorMePreview.state.settings.firstRun'), 'finish onboarding');
  assert.equal(await evaluate("window.__mirrorMePreview.state.settings.deviceName"), 'Desk PC');
  assert.equal(await evaluate("window.__mirrorMePreview.calls.filter(call => call[0] === 'start').length"), 1);
  results.push({ name: 'keyboard-onboarding-minimum-window', passed: true });

  await open('route=settings');
  assert.equal(await evaluate(`(() => {
    const input = document.querySelector('#field-deviceName');
    input.focus(); input.value = 'Living room PC'; input.setSelectionRange(3, 7);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    window.__mirrorMePreview.setStatus('connecting');
    return document.activeElement === input && input.selectionStart === 3 && input.selectionEnd === 7
      && document.querySelector('[data-save-bar]').hidden === false;
  })()`), true, 'live receiver updates must preserve the focused input and selection');
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 's', code: 'KeyS', modifiers: 2, windowsVirtualKeyCode: 83 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 's', code: 'KeyS', modifiers: 2, windowsVirtualKeyCode: 83 });
  await until(() => evaluate("window.__mirrorMePreview.state.settings.deviceName === 'Living room PC' && !window.__mirrorMePreview.state.saving"), 'save with Ctrl+S');
  assert.equal(await evaluate("document.activeElement.id === 'field-deviceName' && document.activeElement.selectionStart === 3 && document.activeElement.selectionEnd === 7"), true, 'saving must preserve keyboard focus and selection');
  await evaluate(`document.querySelector('#field-requirePin').click()`);
  assert.equal(await evaluate("Boolean(document.querySelector('.pin-setting'))"), true, 'pairing controls must appear immediately');
  await evaluate("document.querySelector('#nav-home').click()");
  assert.equal(await evaluate("document.querySelector('dialog').matches(':modal') && document.activeElement.id === 'dialog-cancel'"), true, 'unsaved edits need a focused, modal confirmation');
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await until(() => evaluate('!document.querySelector("dialog")'), 'close confirmation with Escape');
  assert.equal(await evaluate("window.__mirrorMePreview.state.route === 'settings' && window.__mirrorMePreview.state.draft.requirePin"), true, 'Escape must keep edits');
  await evaluate("document.querySelector('#action-revert-settings').click()");
  await evaluate("document.querySelector('#tab-app').click()");
  await evaluate(`(() => {
    const select = document.querySelector('#field-theme');
    select.value = 'dark'; select.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  assert.equal(await evaluate("document.documentElement.dataset.mode"), 'dark', 'theme changes should preview immediately');
  await evaluate("document.querySelector('#action-revert-settings').click()");
  assert.equal(await evaluate("document.documentElement.dataset.mode"), 'light', 'Revert should undo the preview');
  await evaluate("document.querySelector('#tab-picture').focus()");
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'ArrowRight', code: 'ArrowRight', windowsVirtualKeyCode: 39 });
  assert.equal(await evaluate("window.__mirrorMePreview.state.settingsSection"), 'app', 'arrow keys should select the next settings tab');
  results.push({ name: 'keyboard-drafts-focus-theme', passed: true });

  await open('state=advertising');
  await evaluate("document.querySelector('#home-guide').click()");
  await check('connection-guide');
  await screenshot('connection-guide');
  assert.equal(await evaluate("document.querySelector('dialog').matches(':modal')"), true);
  await evaluate("document.querySelector('#disclosure-guide-trouble').click()");
  const scroll = await evaluate(`(() => {
    const dialog = document.querySelector('dialog'); dialog.scrollTop = 180;
    const previous = dialog.scrollTop; window.__mirrorMePreview.setStatus('connecting');
    return { previous, current: document.querySelector('dialog').scrollTop };
  })()`);
  assert.equal(scroll.current, scroll.previous, 'live updates must preserve dialog scroll');
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
  assert.equal(await evaluate("document.querySelector('dialog').contains(document.activeElement)"), true, 'keyboard focus must stay inside the guide');

  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-reduced-motion', value: 'reduce' }, { name: 'prefers-color-scheme', value: 'dark' }] });
  await open('state=connecting&theme=system');
  assert.equal(await evaluate('document.documentElement.dataset.mode'), 'dark');
  assert.equal(await evaluate("getComputedStyle(document.querySelector('.spin')).animationName"), 'none');
  await check('reduced-motion-system-theme');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'forced-colors', value: 'active' }] });
  await open('route=settings');
  await check('windows-high-contrast');
  await screenshot('high-contrast');
  assert.deepEqual([...externalRequests], [], 'the UI must not need external fonts, styles, or scripts');
  await writeFile(join(output, 'results.json'), JSON.stringify(results, null, 2));
  console.log(`Passed ${results.length} browser scenarios, plus keyboard, focus, modal, and offline-asset assertions.`);
  console.log(`Screenshots and results: ${output}`);
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    await send('Browser.close');
    socket.close();
  }
  if (browser.exitCode === null) {
    const exited = await Promise.race([once(browser, 'exit').then(() => true), delay(5000).then(() => false)]);
    if (!exited) {
      browser.kill();
      await once(browser, 'exit');
    }
  }
  await vite.close();
  await new Promise((resolveClose, reject) => server.close(error => error ? reject(error) : resolveClose()));
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 300 });
}
