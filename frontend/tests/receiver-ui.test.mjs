import assert from 'node:assert/strict';
import { after, beforeEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { createServer } from 'vite';
import { settingsFixture, snapshotFixture } from './fixtures.mjs';

const vite = await createServer({
  root: fileURLToPath(new URL('..', import.meta.url)),
  configFile: false,
  logLevel: 'error',
  optimizeDeps: { noDiscovery: true, include: [] },
  server: { middlewareMode: true, watch: null, hmr: false },
});
const {
  state, load, receiveEngineEvent, receiveSettingsUpdate, startMirroring, stopMirroring,
  beginSetup, dismissFirstRun, saveDraft, regeneratePin, navigate, finishNavigation,
  tickConnection, hasDraftChanges, setDraftField, revertDraft, diagnosticText,
  copyDeviceName, openExternalURL, openDialog, CONNECTION_WAIT_MS,
} = await vite.ssrLoadModule('/src/state.js');
const { renderApp } = await vite.ssrLoadModule('/src/render.js');
const { bindEvents, bindShortcuts } = await vite.ssrLoadModule('/src/events.js');
const { applyTheme } = await vite.ssrLoadModule('/src/theme.js');
const originalWindow = globalThis.window;
const originalDocument = globalThis.document;
const noop = () => {};

after(async () => {
  globalThis.window = originalWindow;
  globalThis.document = originalDocument;
  await vite.close();
});

beforeEach(() => {
  Object.assign(state, {
    settings: { ...settingsFixture }, draft: { ...settingsFixture }, route: 'home',
    status: { status: 'stopped' }, statusSince: 0, connectionSlow: false,
    activity: [], toasts: [], error: '', fieldError: '', busy: false, busyAction: '',
    saving: false, maximised: false, loading: false, settingsSection: 'connection',
    setupStep: 1, setupName: settingsFixture.deviceName, details: {},
    scrollPositions: {}, dialog: null, returnFocus: '', focusTarget: '',
  });
  globalThis.document = undefined;
  globalThis.window = {
    matchMedia: () => ({ matches: false }),
    go: { main: { App: {
      GetSettings: async () => ({ ...settingsFixture }),
      GetStatus: async () => ({ status: 'starting' }),
      GetVersion: async () => 'test',
      GetSettingsFolder: async () => 'settings',
      SaveSettings: async next => ({ ...next }),
      StartMirroring: async () => {},
      StopMirroring: async () => {},
      OpenExternalURL: async () => {},
    } } },
    runtime: { WindowIsMaximised: async () => false, ClipboardSetText: async () => true },
  };
});

function renderHTML() {
  const app = { innerHTML: '', querySelector: () => null };
  renderApp(app);
  return app.innerHTML;
}

function buttonHTML(html, action) {
  return html.match(new RegExp(`<button\\b[^>]*data-action="${action}"[^>]*>[\\s\\S]*?<\\/button>`))?.[0];
}

test('startup, connection, and discovery setup can all be cancelled', () => {
  for (const status of ['starting', 'connecting', 'needs-setup']) {
    state.status = { status };
    const button = buttonHTML(renderHTML(), 'stop-mirroring');
    assert.ok(button, `missing Cancel for ${status}`);
    assert.match(button, />Cancel</);
    assert.doesNotMatch(button, /\bdisabled\b/);
  }
});

test('Cancel stays enabled while a start command is pending', () => {
  state.status = { status: 'starting' };
  state.busy = true;
  state.busyAction = 'start';
  assert.doesNotMatch(buttonHTML(renderHTML(), 'stop-mirroring'), /\bdisabled\b/);
});

test('a live ready event wins over an older initial status request', async () => {
  let resolveSettings;
  window.go.main.App.GetSettings = () => new Promise(resolve => { resolveSettings = resolve; });
  const loading = load(noop);
  receiveEngineEvent({ Snapshot: { status: 'advertising' }, Activity: 'Ready' }, noop);
  resolveSettings({ ...settingsFixture });
  await loading;
  assert.equal(state.status.status, 'advertising');
  assert.equal(state.activity[0].text, 'Ready');
});

test('a live startup error is not replaced by an older initial status request', async () => {
  let resolveSettings;
  window.go.main.App.GetSettings = () => new Promise(resolve => { resolveSettings = resolve; });
  const loading = load(noop);
  receiveEngineEvent({ Snapshot: { status: 'error', lastError: 'Receiver did not become ready.' } }, noop);
  resolveSettings({ ...settingsFixture });
  await loading;
  assert.equal(state.status.status, 'error');
  assert.match(renderHTML(), /Receiver did not become ready\./);
  assert.ok(buttonHTML(renderHTML(), 'start-mirroring'));
});

test('newer settings events also win over initial loading', async () => {
  let resolveSettings;
  window.go.main.App.GetSettings = () => new Promise(resolve => { resolveSettings = resolve; });
  const loading = load(noop);
  receiveSettingsUpdate({ ...settingsFixture, deviceName: 'Newer PC' }, noop);
  resolveSettings({ ...settingsFixture });
  await loading;
  assert.equal(state.settings.deviceName, 'Newer PC');
});

test('initial-load errors provide recovery rather than an endless loading screen', async () => {
  state.settings = null;
  state.draft = null;
  window.go.main.App.GetSettings = async () => { throw new Error('Cannot read settings'); };
  await load(noop);
  assert.equal(state.loading, false);
  assert.match(renderHTML(), /Cannot read settings/);
  assert.ok(buttonHTML(renderHTML(), 'reload'));
});

test('opening help before settings load gives feedback without rendering an invalid dialog', () => {
  state.settings = null;
  state.draft = null;
  openDialog('guide', noop);
  assert.equal(state.dialog, null);
  assert.match(state.toasts[0].message, /Try again/);
});

test('Cancel invokes the stop binding and restores the controls', async () => {
  let stopped = 0;
  window.go.main.App.StopMirroring = async () => { stopped++; };
  await stopMirroring(noop);
  assert.equal(stopped, 1);
  assert.equal(state.busy, false);
});

test('a superseded start completion does not unlock a still-running cancellation', async () => {
  let failStart;
  let finishStop;
  window.go.main.App.StartMirroring = () => new Promise((_, reject) => { failStart = reject; });
  window.go.main.App.StopMirroring = () => new Promise(resolve => { finishStop = resolve; });
  const starting = startMirroring(noop);
  const stopping = stopMirroring(noop);
  failStart(new Error('Cancelled start'));
  await starting;
  assert.equal(state.busyAction, 'stop');
  assert.equal(state.busy, true);
  finishStop();
  await stopping;
  assert.equal(state.busy, false);
  assert.equal(state.error, '');
});

test('first run is one focused setup rather than stacked status and welcome cards', () => {
  state.settings.firstRun = true;
  const html = renderHTML();
  assert.match(html, /Step 1 of 2/);
  assert.match(html, /id="setup-name"/);
  assert.doesNotMatch(html, /Recent activity|class="mirror-stage"/);
  assert.ok(buttonHTML(html, 'dismiss-first-run'));
});

test('onboarding saves the chosen name before starting and finishes only when requested', async () => {
  state.settings.firstRun = true;
  state.draft.firstRun = true;
  state.setupName = '  Living room PC  ';
  const calls = [];
  window.go.main.App.SaveSettings = async next => { calls.push(['save', next]); return next; };
  window.go.main.App.StartMirroring = async () => { calls.push(['start']); };
  await beginSetup(noop);
  assert.equal(calls[0][0], 'save');
  assert.equal(calls[0][1].deviceName, 'Living room PC');
  assert.equal(calls[1][0], 'start');
  assert.equal(state.setupStep, 2);
  assert.equal(state.settings.firstRun, true);
  await dismissFirstRun(noop);
  assert.equal(state.settings.firstRun, false);
});

test('onboarding and Settings share one PC-name draft', () => {
  state.settings.firstRun = true;
  state.draft.firstRun = true;
  state.setupName = 'Draft PC';
  setDraftField('deviceName', 'Draft PC', noop);
  navigate('settings', noop);
  assert.equal(state.dialog.kind, 'unsaved');
  receiveSettingsUpdate({ ...settingsFixture, firstRun: true, theme: 'dark' }, noop);
  assert.equal(state.setupName, 'Draft PC');
  revertDraft(noop);
  assert.equal(state.setupName, settingsFixture.deviceName);
});

test('finishing the name step clears normalization-only differences', async () => {
  state.settings.firstRun = true;
  state.draft.firstRun = true;
  state.setupName = '  Desk PC  ';
  state.draft.deviceName = state.setupName;
  await beginSetup(noop);
  assert.equal(state.setupName, 'Desk PC');
  assert.equal(state.draft.deviceName, 'Desk PC');
  assert.equal(hasDraftChanges(), false);
});

test('a failed onboarding save never starts the receiver or skips a step', async () => {
  let started = false;
  window.go.main.App.SaveSettings = async () => { throw new Error('Save failed'); };
  window.go.main.App.StartMirroring = async () => { started = true; };
  await beginSetup(noop);
  assert.equal(started, false);
  assert.equal(state.setupStep, 1);
  assert.equal(state.saving, false);
  assert.equal(state.error, 'Save failed');
});

test('onboarding explains administrator permission before asking for it', () => {
  state.settings.firstRun = true;
  state.setupStep = 2;
  state.status = { status: 'needs-setup' };
  const html = renderHTML();
  assert.match(html, /Bonjour/);
  assert.match(html, /administrator permission/);
  assert.ok(buttonHTML(html, 'confirm-setup'));
  assert.doesNotMatch(buttonHTML(html, 'dismiss-first-run'), /btn-primary/);
});

test('runtime setup explains the upstream download before asking for permission', () => {
  state.status = { status: 'needs-setup', setupKind: 'runtime' };
  const html = renderHTML();
  assert.match(html, /Download 113 MB/);
  assert.match(html, /UxPlay Windows project on GitHub/);
  assert.match(buttonHTML(html, 'confirm-setup'), /Download receiver files/);
  assert.doesNotMatch(html, /Allow discovery/);
});

test('runtime download reports progress and stays cancellable', () => {
  state.status = { status: 'starting', setupKind: 'runtime', setupProgress: 42 };
  const html = renderHTML();
  assert.match(html, /GitHub: 42%/);
  assert.doesNotMatch(buttonHTML(html, 'stop-mirroring'), /\bdisabled\b/);
});

test('an empty PC name produces a field error instead of quietly replacing the name', async () => {
  state.setupName = ' ';
  await beginSetup(noop);
  assert.match(state.fieldError, /Give this PC a name/);
  state.route = 'settings';
  state.draft.deviceName = ' ';
  assert.equal(await saveDraft(noop), false);
  assert.equal(state.focusTarget, 'field-deviceName');
});

test('waiting for video offers recovery after twelve seconds without claiming mirroring', () => {
  state.status = snapshotFixture('connecting');
  state.statusSince = 1000;
  let renders = 0;
  tickConnection(() => { renders++; }, 1000 + CONNECTION_WAIT_MS - 1);
  assert.equal(state.connectionSlow, false);
  tickConnection(() => { renders++; }, 1000 + CONNECTION_WAIT_MS);
  tickConnection(() => { renders++; }, 1000 + CONNECTION_WAIT_MS + 5000);
  assert.equal(renders, 1);
  const html = renderHTML();
  assert.match(html, /video hasn't arrived/);
  assert.ok(buttonHTML(html, 'start-mirroring'));
  assert.ok(buttonHTML(html, 'stop-mirroring'));
  assert.doesNotMatch(html, /You're mirroring|class="icon spin"/);
});

test('a new connection resets the old wait warning', () => {
  state.status = snapshotFixture('connecting');
  state.statusSince = 1000;
  state.connectionSlow = true;
  receiveEngineEvent({ Snapshot: { ...snapshotFixture('connecting'), deviceName: 'Another preview phone' } }, noop);
  assert.equal(state.connectionSlow, false);
  assert.ok(state.statusSince > 1000);
});

test('received video is distinct from rendered video and points to display settings', () => {
  state.status = { ...snapshotFixture('connecting'), videoReceived: true };
  let html = renderHTML();
  assert.match(html, /Opening your mirrored screen/);
  assert.doesNotMatch(html, /You're mirroring/);
  assert.match(diagnosticText(), /Video: Received, not displayed/);
  state.connectionSlow = true;
  html = renderHTML();
  assert.match(html, /Windows has not displayed it/);
  assert.match(html, /software decoding/);
  assert.ok(buttonHTML(html, 'picture-settings'));
});

test('the first encoded video starts a fresh display wait', () => {
  state.status = snapshotFixture('connecting');
  state.statusSince = 1000;
  state.connectionSlow = true;
  receiveEngineEvent({ Snapshot: { ...state.status, videoReceived: true } }, noop);
  assert.equal(state.connectionSlow, false);
  assert.ok(state.statusSince > 1000);
});

test('the elapsed display is present only for a receiver-reported mirroring session', () => {
  state.status = snapshotFixture('connecting');
  assert.doesNotMatch(renderHTML(), /data-elapsed/);
  state.status = snapshotFixture('mirroring');
  assert.match(renderHTML(), /data-elapsed/);
  assert.ok(buttonHTML(renderHTML(), 'show-mirrored-screen'));
});

test('receiver events update status without rebuilding Settings', () => {
  state.route = 'settings';
  state.draft.deviceName = 'An unsaved name';
  let options;
  receiveEngineEvent({ Snapshot: snapshotFixture('connecting') }, value => { options = value; });
  assert.equal(options.statusOnly, true);
  assert.equal(state.draft.deviceName, 'An unsaved name');
});

test('navigating away with edits asks whether to keep them', () => {
  state.route = 'settings';
  state.draft.deviceName = 'Unsaved PC';
  navigate('home', noop);
  assert.equal(state.route, 'settings');
  assert.deepEqual(state.dialog, { kind: 'unsaved', target: 'home' });
  assert.match(renderHTML(), /Save your changes\?/);
});

test('discarding restores saved values and completes navigation', async () => {
  state.route = 'settings';
  state.draft.theme = 'dark';
  navigate('home', noop);
  await finishNavigation(false, noop);
  assert.equal(state.route, 'home');
  assert.equal(state.draft.theme, settingsFixture.theme);
  assert.equal(hasDraftChanges(), false);
});

test('save-and-leave persists edits before changing pages', async () => {
  state.route = 'settings';
  state.draft.deviceName = 'Saved PC';
  navigate('home', noop);
  await finishNavigation(true, noop);
  assert.equal(state.route, 'home');
  assert.equal(state.settings.deviceName, 'Saved PC');
  assert.equal(state.dialog, null);
});

test('save failures preserve edits and keep the recovery dialog open', async () => {
  state.route = 'settings';
  state.draft.deviceName = 'Unsaved PC';
  window.go.main.App.SaveSettings = async () => { throw new Error('Disk unavailable'); };
  navigate('home', noop);
  await finishNavigation(true, noop);
  assert.equal(state.route, 'settings');
  assert.equal(state.dialog.kind, 'unsaved');
  assert.equal(state.draft.deviceName, 'Unsaved PC');
  assert.equal(state.error, 'Disk unavailable');
});

test('background settings updates preserve only edited fields', () => {
  state.draft.deviceName = 'My draft';
  receiveSettingsUpdate({ ...settingsFixture, theme: 'dark' }, noop);
  assert.equal(state.draft.deviceName, 'My draft');
  assert.equal(state.draft.theme, 'dark');
});

test('generating a new pairing code does not discard unrelated edits', async () => {
  state.settings.requirePin = true;
  state.settings.pinCode = '1234';
  state.draft = { ...state.settings, deviceName: 'Unsaved name', audioEnabled: false };
  window.go.main.App.RegeneratePinCode = async () => {
    const saved = { ...state.settings, pinCode: '5678' };
    receiveSettingsUpdate(saved, noop);
    return saved;
  };
  await regeneratePin(noop);
  assert.equal(state.draft.deviceName, 'Unsaved name');
  assert.equal(state.draft.audioEnabled, false);
  assert.equal(state.draft.pinCode, '5678');
  assert.equal(state.settings.deviceName, settingsFixture.deviceName);
});

test('all original settings remain reachable in the three categories', () => {
  state.route = 'settings';
  let html = '';
  for (const section of ['connection', 'picture', 'app']) {
    state.settingsSection = section;
    html += renderHTML();
  }
  for (const field of Object.keys(settingsFixture).filter(key => !['firstRun', 'pinCode'].includes(key))) {
    assert.match(html, new RegExp(`data-field="${field}"`), `missing ${field}`);
  }
});

test('advanced controls start collapsed and remember an opened disclosure', () => {
  state.route = 'settings';
  let html = renderHTML();
  assert.doesNotMatch(html.match(/<details[^>]*data-disclosure="advanced-connection"[^>]*>/)[0], /\bopen\b/);
  state.details['advanced-connection'] = true;
  html = renderHTML();
  assert.match(html.match(/<details[^>]*data-disclosure="advanced-connection"[^>]*>/)[0], /\bopen\b/);
});

test('new pairing-code controls appear immediately when the draft enables pairing', () => {
  state.route = 'settings';
  setDraftField('requirePin', true, noop);
  const html = renderHTML();
  assert.match(html, /A code will be created when you save/);
  assert.match(buttonHTML(html, 'regenerate-pin'), /\bdisabled\b/);
  revertDraft(noop);
  assert.doesNotMatch(renderHTML(), /A code will be created when you save/);
});

test('text fields and switches have explicit, separate accessible names and descriptions', () => {
  state.route = 'settings';
  const html = renderHTML();
  assert.match(html, /<label for="field-deviceName">PC name<\/label>/);
  assert.match(html, /aria-labelledby="label-requirePin" aria-describedby="hint-requirePin"/);
  assert.match(html, /aria-selected="true" aria-controls="panel-connection"/);
});

test('light, dark, and system theme selection use the same design-system attribute', () => {
  globalThis.document = { documentElement: { dataset: {} } };
  applyTheme('dark');
  assert.equal(document.documentElement.dataset.mode, 'dark');
  applyTheme('light');
  assert.equal(document.documentElement.dataset.mode, 'light');
  window.matchMedia = () => ({ matches: true });
  applyTheme('system');
  assert.equal(document.documentElement.dataset.mode, 'dark');
});

test('event delegation is registered once, even after repeated renders', () => {
  const registrations = [];
  const app = { addEventListener: (name, callback) => registrations.push([name, callback]) };
  bindEvents(app, noop);
  bindEvents(app, noop);
  assert.equal(registrations.filter(([name]) => name === 'click').length, 1);
});

test('the native-style keyboard shortcuts open Settings and the connection guide', () => {
  let keydown;
  bindShortcuts({ addEventListener: (_, handler) => { keydown = handler; } }, noop);
  let prevented = false;
  keydown({ key: ',', ctrlKey: true, preventDefault: () => { prevented = true; } });
  assert.equal(state.route, 'settings');
  assert.equal(prevented, true);
  keydown({ key: 'F1', preventDefault: noop });
  assert.equal(state.dialog.kind, 'guide');
});

test('desktop shortcuts never open the browser Save Page or Help commands', () => {
  let keydown;
  bindShortcuts({ addEventListener: (_, handler) => { keydown = handler; } }, noop);
  let prevented = 0;
  keydown({ key: 's', ctrlKey: true, preventDefault: () => { prevented++; } });
  state.dialog = { kind: 'guide' };
  keydown({ key: 'F1', preventDefault: () => { prevented++; } });
  assert.equal(prevented, 2);
  assert.equal(state.dialog.kind, 'guide');
});

test('theme previews also restore the native window to the Windows preference', () => {
  globalThis.document = { documentElement: { dataset: {} } };
  const calls = [];
  window.runtime.WindowSetDarkTheme = () => { calls.push('dark'); };
  window.runtime.WindowSetSystemDefaultTheme = () => { calls.push('system'); };
  applyTheme('dark', true);
  applyTheme('system', true);
  assert.deepEqual(calls, ['dark', 'system']);
});

test('diagnostics omit saved pairing codes and settings paths', () => {
  state.settings.pinCode = 'secret-pairing-code';
  state.settingsFolder = 'private-settings-path';
  const text = diagnosticText();
  assert.doesNotMatch(text, /secret-pairing-code|private-settings-path/);
  assert.match(text, /Receiver: stopped/);
});

test('clipboard and external-link failures are surfaced rather than swallowed', async () => {
  window.runtime.ClipboardSetText = async () => false;
  await copyDeviceName(noop);
  assert.match(state.error, /could not copy/);
  assert.equal(state.toasts.length, 0);
  window.go.main.App.OpenExternalURL = async () => { throw new Error('Browser unavailable'); };
  await openExternalURL('https://wails.io', noop);
  assert.equal(state.error, 'Browser unavailable');
});

test('names and diagnostics are rendered as text, not markup', () => {
  state.settings.deviceName = '<preview> & "name"';
  state.activity = [{ time: new Date(), text: '<diagnostic>' }];
  const html = renderHTML();
  assert.match(html, /&lt;preview&gt; &amp; &quot;name&quot;/);
  assert.match(html, /&lt;diagnostic&gt;/);
  assert.doesNotMatch(html, /<preview>|<diagnostic>/);
});

test('the About page explains one tray icon without an extra desktop receiver UI', () => {
  state.route = 'about';
  assert.match(renderHTML(), /One app, one tray icon/);
  assert.doesNotMatch(renderHTML(), /Two tray icons are normal/);
});
