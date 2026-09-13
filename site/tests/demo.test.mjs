import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { initialState, reduce } from '../demo.mjs';
import { createPreviewBridge, exampleSettings } from '../../frontend/preview/bridge.mjs';

test('the example is already mirroring, with no start or playback stage', () => {
  const state = initialState();
  assert.equal(state.phase, 'mirroring');
  assert.equal(state.videoMinimised, false);
  assert.deepEqual(Object.keys(state).sort(), ['landscape', 'motion', 'phase', 'videoMinimised']);
});
test('photo orientation and motion preferences survive a reconnect', () => {
  let state = reduce(initialState(), { type: 'rotate' });
  state = reduce(state, { type: 'motion', value: false });
  state = reduce(state, { type: 'status', value: 'stopped' });
  state = reduce(state, { type: 'status', value: 'mirroring' });
  assert.equal(state.landscape, true);
  assert.equal(state.motion, false);
});
test('minimizing the video does not disconnect the example phone', () => {
  const state = reduce(initialState(), { type: 'minimise-video' });
  assert.equal(state.phase, 'mirroring');
  assert.equal(state.videoMinimised, true);
  assert.equal(reduce(state, { type: 'show-video' }).videoMinimised, false);
});
test('photo motion respects the initial preference and can be toggled', () => {
  let state = initialState(true);
  assert.equal(state.motion, false);
  state = reduce(state, { type: 'motion', value: true });
  assert.equal(state.motion, true);
  assert.equal(reduce(state, { type: 'motion', value: false }).motion, false);
});
test('reset restores a connected, portrait photo using the current motion preference', () => {
  assert.deepEqual(initialState(true), { phase: 'mirroring', landscape: false, motion: false, videoMinimised: false });
  assert.equal(initialState().motion, true);
});
test('only the photo example remains, without content selection or timer code', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  const script = await readFile(new URL('../app.mjs', import.meta.url), 'utf8');
  const styles = await readFile(new URL('../style.css', import.meta.url), 'utf8');
  assert.equal((html.match(/class="sample /g) || []).length, 1);
  assert.match(html, /class="sample photos"/);
  assert.match(html, /id="rotate"/);
  assert.match(html, /id="motion"/);
  assert.doesNotMatch(html, /data-content|note-editor|demo-note|sample notes|sample clock|stopwatch/i);
  assert.doesNotMatch(script, /setInterval|formatTime|DEFAULT_NOTE|data-note|data-clock|data-content/);
  assert.doesNotMatch(styles, /\.(?:notes|clock|content-switch|note-editor|sample-eyebrow)(?=[\s:{.-])/);
});
test('unknown interactions cannot silently invent a preview state', () => {
  assert.throws(() => reduce(initialState(), { type: 'content', value: 'camera' }));
  assert.throws(() => reduce(initialState(), { type: 'status', value: 'connecting' }));
  assert.throws(() => reduce(initialState(), { type: 'unsupported' }));
});
test('the native bridge starts with an explicit example phone and isolated settings', async () => {
  const bridge = createPreviewBridge({ now: () => 1000 });
  assert.deepEqual(await bridge.app.GetSettings(), exampleSettings());
  const status = await bridge.app.GetStatus();
  assert.equal(status.status, 'mirroring');
  assert.equal(status.deviceName, 'Example iPhone');
  assert.equal(status.connectedAt, new Date(1000).toISOString());
  status.deviceName = 'Mutated caller';
  const settings = await bridge.app.GetSettings();
  settings.deviceName = 'Changed without saving';
  assert.equal((await bridge.app.GetSettings()).deviceName, 'Studio PC');
  assert.equal((await bridge.app.GetStatus()).deviceName, 'Example iPhone');
});
test('the bridge saves, generates example pairing codes, emits updates, and resets only in memory', async () => {
  const bridge = createPreviewBridge();
  const events = [];
  const off = bridge.runtime.EventsOnMultiple('settings-updated', event => events.push(event));
  const saved = await bridge.app.SaveSettings({ ...exampleSettings(), deviceName: ' Desk PC ', requirePin: true });
  assert.equal(saved.deviceName, 'Desk PC');
  assert.equal(saved.pinCode, '2468');
  assert.equal((await bridge.app.RegeneratePinCode()).pinCode, '1357');
  assert.equal(events.length, 2);
  await assert.rejects(bridge.app.SaveSettings({ ...saved, deviceName: ' ' }), /PC name/);
  await assert.rejects(bridge.app.SaveSettings({ ...saved, deviceName: 'x'.repeat(65) }), /PC name/);
  off();
  bridge.reset('dark');
  assert.deepEqual(await bridge.app.GetSettings(), exampleSettings('dark'));
  assert.equal(events.length, 2);
  assert.equal((await bridge.app.GetStatus()).status, 'mirroring');
  assert.equal((await createPreviewBridge().app.GetSettings()).deviceName, 'Studio PC');
});
test('all receiver and window interactions are visible simulations', async () => {
  const messages = [];
  const events = [];
  const bridge = createPreviewBridge({ notify: event => messages.push(event) });
  bridge.runtime.EventsOnMultiple('engine-status', event => events.push(event.Snapshot.status));
  assert.equal(await bridge.app.ShowMirroredScreen(), true);
  assert.deepEqual(messages.pop(), { type: 'window', action: 'show-video' });
  bridge.runtime.WindowMinimise();
  bridge.runtime.WindowHide();
  assert.equal((await bridge.app.GetStatus()).status, 'mirroring');
  bridge.runtime.WindowToggleMaximise();
  assert.equal(await bridge.runtime.WindowIsMaximised(), true);
  bridge.runtime.WindowToggleMaximise();
  assert.equal(await bridge.runtime.WindowIsMaximised(), false);
  await bridge.app.StopMirroring();
  assert.equal(await bridge.app.ShowMirroredScreen(), false);
  await bridge.app.StartMirroring();
  bridge.connect();
  bridge.closeVideo();
  bridge.connect();
  await bridge.app.Quit();
  assert.deepEqual(events, ['stopped', 'advertising', 'mirroring', 'advertising', 'mirroring', 'stopped']);
  assert.deepEqual(messages.at(-1), { type: 'window', action: 'quit' });
});
test('native-only actions explicitly refuse rather than pretending to change the PC', async () => {
  const bridge = createPreviewBridge();
  for (const call of [
    () => bridge.app.ConfirmSetupAndStart(),
    () => bridge.app.OpenSettingsFolder(),
    () => bridge.app.OpenExternalURL('https://example.com/'),
    () => bridge.runtime.ClipboardSetText('example'),
  ]) await assert.rejects(call, /installed app, not this browser preview/);
  assert.throws(() => bridge.setTheme('invalid'), /Unknown preview theme/);
  assert.equal((await bridge.app.GetStatus()).status, 'mirroring');
});
test('the preview implements the entire application-facing native boundary', async () => {
  const source = await readFile(new URL('../../frontend/wailsjs/go/main/App.js', import.meta.url), 'utf8');
  const bridge = createPreviewBridge();
  for (const [, name] of source.matchAll(/export function (\w+)\(/g)) {
    assert.equal(typeof bridge.app[name], 'function', `Missing preview method: ${name}`);
  }
  const routes = [];
  bridge.runtime.EventsOnMultiple('navigate', route => routes.push(route));
  await bridge.app.ShowSettingsPage();
  await bridge.app.ShowAboutPage();
  assert.deepEqual(routes, ['settings', 'about']);
});
test('the page embeds the real app, with immediate video and truthful preview limits', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  assert.match(html, /releases\/download\/v0\.1\.0-preview\.1\/MirrorMe-windows-x64\.zip/);
  assert.match(html, /Real interface &middot; Example data/);
  assert.match(html, /src="\.\/preview\/index\.html"/);
  assert.match(html, /Direct3D12 Renderer/);
  assert.match(html, /113 MB/);
  assert.match(html, /Physical-iPhone mirroring/);
  assert.match(html, /data-phase="mirroring"/);
  assert.doesNotMatch(html, /id="connect"|Start demo|Play demo|demo-sidebar|releases\/latest|src="https:|href="\/(?:assets|style)/);
  assert.match(html, /connect-src 'none'/);
  assert.match(html, /camera 'none'; microphone 'none'; display-capture 'none'/);
});
test('the generated preview is built from the current desktop sources, without copied screens', async () => {
  const manifest = JSON.parse(await readFile(new URL('../preview/source-manifest.json', import.meta.url), 'utf8'));
  const entry = await readFile(new URL('../../frontend/preview/main.mjs', import.meta.url), 'utf8');
  assert.match(entry, /import\('\.\.\/src\/main\.js'\)/);
  assert.doesNotMatch(entry, /renderApp\(|innerHTML|localStorage|sessionStorage|fetch\(/);
  const files = [];
  const frontend = new URL('../../frontend/', import.meta.url);
  async function collect(directory) {
    for (const file of await readdir(new URL(directory, frontend), { withFileTypes: true })) {
      if (file.isDirectory()) await collect(`${directory}${file.name}/`);
      else files.push(`${directory}${file.name}`);
    }
  }
  for (const directory of ['src/', 'preview/', 'wailsjs/']) await collect(directory);
  files.push('build-preview.mjs', 'package.json', 'package-lock.json');
  assert.deepEqual(Object.keys(manifest.sources).sort(), files.sort(), 'Rebuild when app sources are added or removed');
  for (const [path, hash] of Object.entries(manifest.sources)) {
    const source = (await readFile(new URL(path, frontend), 'utf8')).replaceAll('\r\n', '\n');
    assert.equal(createHash('sha256').update(source).digest('hex'), hash, `Rebuild stale website preview: ${path}`);
  }
  for (const [path, hash] of Object.entries(manifest.assets)) {
    const asset = await readFile(new URL(`../preview/${path}`, import.meta.url));
    assert.equal(createHash('sha256').update(asset).digest('hex'), hash, `Generated preview asset changed: ${path}`);
  }
});
