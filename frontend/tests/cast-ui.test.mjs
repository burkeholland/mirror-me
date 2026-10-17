import assert from 'node:assert/strict';
import { after, beforeEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import { settingsFixture, castSnapshotFixture } from './fixtures.mjs';

const vite = await createServer({
  root: fileURLToPath(new URL('..', import.meta.url)),
  configFile: false, logLevel: 'error', optimizeDeps: { noDiscovery: true, include: [] },
  server: { middlewareMode: true, watch: null, hmr: false },
});
const {
  state, receiveCastEvent, navigate, selectCastTarget, startDesktopCast, stopDesktopCast,
  submitCastPIN, discoverCastTargets, forgetCastTarget, receiveEngineEvent,
} = await vite.ssrLoadModule('/src/state.js');
const { renderApp } = await vite.ssrLoadModule('/src/render.js');
const noop = () => {};
const originalWindow = globalThis.window;
const calls = [];
after(async () => { globalThis.window = originalWindow; await vite.close(); });

beforeEach(() => {
  calls.length = 0;
  Object.assign(state, {
    settings: { ...settingsFixture }, draft: { ...settingsFixture },
    route: 'cast', status: { status: 'advertising' }, details: {}, dialog: null,
    scrollPositions: {}, focusTarget: '', toasts: [], error: '',
    cast: castSnapshotFixture('ready'), castSelected: '', castPin: '', castError: '', castAction: '',
  });
  globalThis.window = { go: { main: { App: {
    GetCastStatus: async () => ({ ...state.cast }),
    DiscoverCastTargets: async () => { calls.push(['discover']); },
    StartDesktopCast: async id => { calls.push(['start', id]); },
    StopDesktopCast: async () => { calls.push(['stop']); },
    SubmitCastPIN: async pin => { calls.push(['pin', pin]); },
    ForgetCastTarget: async id => { calls.push(['forget', id]); },
  } } } };
});

function html() {
  const app = { innerHTML: '', querySelector: () => null };
  renderApp(app);
  return app.innerHTML;
}
function button(action) {
  return html().match(new RegExp(`<button\\b[^>]*data-action="${action}"[^>]*>[\\s\\S]*?<\\/button>`))?.[0];
}

test('casting is a separate route and does not require receiver onboarding', () => {
  state.settings.firstRun = true;
  assert.match(html(), /This PC to Apple TV/);
  assert.doesNotMatch(html(), /id="setup-form"/);
  assert.equal(state.status.status, 'advertising');
});

test('discovery and target selection do not capture; sharing is explicit', async () => {
  await discoverCastTargets(noop);
  assert.deepEqual(calls, [['discover']]);
  assert.match(button('cast-start'), /\bdisabled\b/);
  selectCastTarget(state.cast.targets[0].id, noop);
  assert.equal(calls.length, 1);
  assert.doesNotMatch(button('cast-start'), /\bdisabled\b/);
  assert.match(html(), /including notifications/);
  await startDesktopCast(noop);
  assert.deepEqual(calls.at(-1), ['start', 'AABBCCDDEEFF']);
});

test('discovery animates both loading indicators', () => {
  state.cast.status = 'discovering';
  const result = html();
  assert.match(button('cast-discover'), /class="icon spin"/);
  assert.match(result, /class="cast-empty"[\s\S]*class="icon spin"/);
});

test('source summary avoids a redundant destination illustration', () => {
  const source = html().match(/<section class="cast-source"[\s\S]*?<\/section>/)?.[0] || '';
  assert.match(source, /Your primary display/);
  assert.match(source, /class="cast-source-icon"/);
  assert.equal((source.match(/class="icon /g) || []).length, 1);
  assert.equal((source.match(/class="cast-source-icon"/g) || []).length, 1);
});

test('audio-only devices remain visible but cannot be selected', () => {
  selectCastTarget(state.cast.targets[1].id, noop);
  assert.equal(state.castSelected, '');
  assert.match(html(), /Kitchen speaker/);
  assert.match(html(), /data-target-id="112233445566"[^>]*\bdisabled\b/);
});

test('PIN input is inline, validated, cleared, and never stored in settings', async () => {
  receiveCastEvent(castSnapshotFixture('pairing', 1), noop);
  assert.match(html(), /id="cast-pair-form"/);
  assert.match(html(), /id="cast-pin"/);
  state.castPin = '12x4';
  await submitCastPIN(noop);
  assert.equal(calls.length, 0);
  assert.match(state.castError, /four-digit/);
  state.castPin = '1234';
  await submitCastPIN(noop);
  assert.deepEqual(calls, [['pin', '1234']]);
  assert.equal(state.castPin, '');
  assert.equal(state.settings.pinCode, '');
});

test('old status snapshots cannot undo newer casting events', () => {
  receiveCastEvent(castSnapshotFixture('streaming', 10), noop);
  receiveCastEvent(castSnapshotFixture('connecting', 9), noop);
  assert.equal(state.cast.status, 'streaming');
});

test('Stop stays available during connect and PIN calls', async () => {
  receiveCastEvent(castSnapshotFixture('connecting', 1), noop);
  let finish;
  window.go.main.App.StartDesktopCast = () => new Promise(resolve => { finish = resolve; });
  const pending = startDesktopCast(noop);
  assert.doesNotMatch(button('cast-stop'), /\bdisabled\b/);
  await stopDesktopCast(noop);
  finish();
  await pending;
  assert.deepEqual(calls, [['stop']]);
  assert.equal(state.castAction, '');
});

test('streaming is announced across routes without rebuilding settings', () => {
  state.route = 'settings';
  state.draft.deviceName = 'Unsaved PC name';
  const renders = [];
  receiveCastEvent(castSnapshotFixture('streaming', 1), options => renders.push(options));
  assert.deepEqual(renders, [{ castOnly: true }]);
  assert.match(html(), /Sharing your primary display/);
  assert.match(html(), /cast-banner-stop/);
  assert.equal(state.draft.deviceName, 'Unsaved PC name');
});

test('receiver events leave casting state and PIN untouched', () => {
  receiveCastEvent(castSnapshotFixture('pairing', 1), noop);
  state.castPin = '123';
  const renders = [];
  receiveEngineEvent({ Snapshot: { status: 'mirroring' } }, options => renders.push(options));
  assert.equal(state.castPin, '123');
  assert.equal(state.cast.status, 'pairing');
  assert.deepEqual(renders, [{ statusOnly: true }]);
});

test('network names and sender errors are escaped', () => {
  state.cast.targets[0].name = '<img src=x onerror=alert(1)>';
  state.cast.lastError = '<script>bad()</script>';
  const result = html();
  assert.doesNotMatch(result, /<img|<script/);
  assert.match(result, /&lt;img/);
  assert.match(result, /&lt;script/);
});

test('Mac AirPlay access errors show actionable receiver settings', () => {
  state.cast.lastError = 'Burke’s MacBook Pro is not accepting AirPlay connections from this PC. On the Mac, open System Settings > General > AirDrop & Handoff > AirPlay Receiver. Set Allow AirPlay for to Anyone on the Same Network, turn off Require Password, then turn AirPlay Receiver off and back on.';
  const result = html();
  assert.match(result, /Anyone on the Same Network/);
  assert.match(result, /turn off Require Password/);
  assert.match(result, /turn AirPlay Receiver off and back on/);
  assert.doesNotMatch(result, /POST \/pair-pin-start|403 Forbidden/);
});

test('discovery failure does not masquerade as success and can be retried', async () => {
  window.go.main.App.DiscoverCastTargets = async () => { throw new Error('Multicast unavailable'); };
  await discoverCastTargets(noop);
  assert.match(state.castError, /Multicast unavailable/);
  assert.equal(state.castAction, '');
  assert.doesNotMatch(button('cast-discover'), /\bdisabled\b/);
});

test('navigation never starts or stops desktop capture', () => {
  state.cast = castSnapshotFixture('streaming');
  navigate('home', noop);
  navigate('cast', noop);
  assert.deepEqual(calls, []);
  assert.equal(state.cast.status, 'streaming');
});

test('forgetting pairing calls only the selected target identity', async () => {
  selectCastTarget('AABBCCDDEEFF', noop);
  await forgetCastTarget(noop);
  assert.deepEqual(calls, [['forget', 'AABBCCDDEEFF']]);
});

test('missing helper has an honest unavailable state and no enabled Start', () => {
  state.cast.available = false;
  state.cast.targets = [];
  state.cast.lastError = 'Extract the complete sender bundle.';
  assert.match(html(), /Extract the complete sender bundle/);
  assert.match(button('cast-start'), /\bdisabled\b/);
  assert.match(button('cast-discover'), /\bdisabled\b/);
});

test('a stop failure stays visible with a retry action on other pages', async () => {
  state.route = 'settings';
  state.cast = castSnapshotFixture('streaming', 1);
  window.go.main.App.StopDesktopCast = async () => { throw new Error('Capture has not exited. Quit MirrorMe.'); };
  await stopDesktopCast(noop);
  assert.match(html(), /Capture has not exited\. Quit MirrorMe/);
  state.cast.status = 'error';
  assert.match(html(), /Desktop sharing needs attention/);
  assert.doesNotMatch(button('cast-stop'), /\bdisabled\b/);
});

test('disconnect refresh preserves the selected TV without a warning or automatic capture', async () => {
  selectCastTarget('AABBCCDDEEFF', noop);
  receiveCastEvent(castSnapshotFixture('streaming', 1), noop);
  window.go.main.App.StopDesktopCast = async () => {
    calls.push(['stop']);
    receiveCastEvent(castSnapshotFixture('stopped', 2), noop);
    receiveCastEvent({ ...castSnapshotFixture('discovering', 3), targets: [] }, noop);
  };
  await stopDesktopCast(noop);
  assert.equal(state.cast.status, 'discovering');
  assert.equal(state.castSelected, 'AABBCCDDEEFF');
  assert.match(button('cast-start'), /\bdisabled\b/);
  assert.doesNotMatch(html(), /notice-error/);
  receiveCastEvent(castSnapshotFixture('ready', 4), noop);
  assert.equal(state.castSelected, 'AABBCCDDEEFF');
  assert.doesNotMatch(button('cast-start'), /\bdisabled\b/);
  assert.deepEqual(calls, [['stop']], 'backend owns refresh, never starts capture');
});

test('refreshed results clear a missing selection and retain discovery errors', () => {
  selectCastTarget('AABBCCDDEEFF', noop);
  state.castError = 'Old warning';
  receiveCastEvent({ ...castSnapshotFixture('discovering', 1), targets: [] }, noop);
  assert.equal(state.castError, '');
  receiveCastEvent({ ...castSnapshotFixture('ready', 2), targets: [] }, noop);
  assert.equal(state.castSelected, '');
  assert.match(button('cast-start'), /\bdisabled\b/);
  receiveCastEvent({ ...castSnapshotFixture('error', 3), targets: [], lastError: 'Multicast unavailable' }, noop);
  assert.match(html(), /Multicast unavailable/);
});
