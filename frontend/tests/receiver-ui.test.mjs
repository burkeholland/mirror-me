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
  copyDeviceName, openExternalURL, openDialog, showMirroredScreen, receiveLogWarning, openLogsFolder, CONNECTION_WAIT_MS,
} = await vite.ssrLoadModule('/src/state.js');
const { renderApp, refreshReceiverStatus } = await vite.ssrLoadModule('/src/render.js');
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
    logWarning: '', logsFolder: '', toasts: [], error: '', fieldError: '', busy: false, busyAction: '',
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
      GetLogsFolder: async () => 'logs',
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

test('the connection page explains separate video before and after connecting', () => {
  for (const status of ['stopped', 'starting', 'advertising', 'connecting', 'mirroring']) {
    state.status = { status, deviceName: 'Example iPhone' };
    const html = renderHTML();
    assert.doesNotMatch(html, /home-hint|data-disclosure="home-details"|data-activity-list|Copy details/);
    assert.match(html, /class="scene-caption">Separate video window/);
    if (status === 'mirroring') {
      assert.match(html, /MirrorMe - iPhone screen/);
      assert.ok(buttonHTML(html, 'show-mirrored-screen'));
    }
    assert.doesNotMatch(html, /<video\b/);
  }
});

test('an unnamed native phone is not shown as disconnected', () => {
  state.route = 'settings';
  state.settingsSection = 'app';
  for (const status of ['connecting', 'mirroring', 'paused']) {
    state.status = { status, backend: 'native', deviceName: '' };
    assert.match(renderHTML(), /data-diagnostic-device>Your iPhone</);
    assert.match(diagnosticText(), /Device: Your iPhone/);
  }
  state.status = { status: 'advertising', backend: 'native' };
  assert.match(diagnosticText(), /Device: Not connected/);
});

test('paused mirroring explains recovery without showing a live screen or a connection warning', () => {
  state.status = { status: 'paused', backend: 'native', videoReceived: false, connectedAt: null };
  state.connectionSlow = true;
  const html = renderHTML();
  assert.match(html, /Mirroring is paused/);
  assert.match(html, /data-receiver-label>Paused</);
  assert.doesNotMatch(html, /data-diagnostic-status/);
  assert.match(html, /Unlock your iPhone to resume/);
  assert.match(html, /stop <strong>Screen Mirroring<\/strong> on your iPhone, then choose this PC again/);
  assert.match(buttonHTML(html, 'stop-mirroring'), /Stop mirroring/);
  assert.doesNotMatch(buttonHTML(html, 'stop-mirroring'), /\bdisabled\b/);
  assert.equal(buttonHTML(html, 'show-mirrored-screen'), undefined);
  assert.equal(buttonHTML(html, 'start-mirroring'), undefined);
  assert.doesNotMatch(html, /You're mirroring|is sharing its screen|data-elapsed|connection-progress|video hasn't arrived/);
  assert.match(diagnosticText(), /Receiver: paused/);
  assert.match(diagnosticText(), /Video: Paused, not displayed/);
});

test('a paused receiver keeps Stop available while a start or settings save is pending', () => {
  state.status = snapshotFixture('paused');
  state.busy = true;
  state.busyAction = 'start';
  state.saving = true;
  assert.doesNotMatch(buttonHTML(renderHTML(), 'stop-mirroring'), /\bdisabled\b/);
  state.busyAction = 'stop';
  assert.match(buttonHTML(renderHTML(), 'stop-mirroring'), /\bdisabled\b/);
});

test('a stale Show screen action cannot reopen a paused video window', async () => {
  let shows = 0;
  window.go.main.App.ShowMirroredScreen = async () => { shows++; return true; };
  state.status = snapshotFixture('paused');
  await showMirroredScreen(noop);
  assert.equal(shows, 0);
  assert.equal(state.toasts.length, 0);
  state.status = snapshotFixture('mirroring');
  await showMirroredScreen(noop);
  assert.equal(shows, 1);
});

test('onboarding handles a receiver pause without claiming success or waiting for discovery', () => {
  state.settings.firstRun = true;
  state.setupStep = 2;
  state.status = snapshotFixture('paused');
  const html = renderHTML();
  assert.match(html, /Mirroring is paused/);
  assert.match(html, /Unlock your iPhone to resume/);
  assert.match(html, /hidden until video resumes/);
  assert.match(buttonHTML(html, 'stop-mirroring'), /Stop mirroring/);
  assert.match(buttonHTML(html, 'dismiss-first-run'), />Done</);
  assert.equal(buttonHTML(html, 'show-mirrored-screen'), undefined);
  assert.doesNotMatch(html, /Once this PC is ready|You're connected|is mirroring\.|connection-progress/);
});

test('Help and the connection guide explain receiver-reported pause and phone-side recovery', () => {
  state.status = snapshotFixture('paused');
  state.route = 'about';
  let html = renderHTML();
  assert.match(html, /data-disclosure="help-paused"/);
  assert.match(html, /receiver reported a pause/);
  assert.match(html, /Unlock your iPhone to resume/);
  assert.match(html, /choose this PC again/);
  openDialog('guide', noop);
  html = renderHTML();
  const dialog = html.slice(html.indexOf('<dialog'));
  assert.match(dialog, /Mirroring is paused/);
  assert.match(dialog, /Unlock your iPhone to resume/);
  assert.doesNotMatch(dialog, /class="connection-steps"/);
});

test('native picture settings describe the decoder that is actually used', () => {
  state.status = { status: 'advertising', backend: 'native' };
  state.route = 'settings';
  state.settingsSection = 'picture';
  const html = renderHTML();
  assert.match(html, /This preview uses software decoding/);
  assert.doesNotMatch(html, /data-field="hardwareDecode"/);
  assert.match(html, /data-field="h265"/);
});

test('native receiver guidance has no runtime-download or service-install step', () => {
  state.status = { status: 'advertising', backend: 'native' };
  let html = renderHTML();
  assert.doesNotMatch(html, /data-diagnostic-status/);
  assert.doesNotMatch(html, /Download receiver files|Allow discovery|113 MB/);
  state.route = 'about';
  html = renderHTML();
  assert.match(html, /AirPlay protocol code and audio codecs are built into MirrorMe/);
  assert.match(html, /No separate receiver download or discovery service is installed/);
  assert.doesNotMatch(html, /GStreamer|uses UxPlay/);
});

test('a live ready event wins over an older initial status request', async () => {
  let resolveSettings;
  window.go.main.App.GetSettings = () => new Promise(resolve => { resolveSettings = resolve; });
  const loading = load(noop);
  receiveEngineEvent({ Snapshot: { status: 'advertising' }, Activity: 'Ready' }, noop);
  resolveSettings({ ...settingsFixture });
  await loading;
  assert.equal(state.status.status, 'advertising');
  assert.doesNotMatch(diagnosticText(), /Recent activity/);
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

test('discovery name limits are checked before saving or starting', async () => {
  let saves = 0;
  window.go.main.App.SaveSettings = async next => { saves++; return next; };
  state.setupName = '\u754c'.repeat(17);
  await beginSetup(noop);
  assert.equal(saves, 0);
  assert.match(state.fieldError, /shorter PC name/);
  state.draft.deviceName = 'a'.repeat(51);
  assert.equal(await saveDraft(noop), false);
  assert.equal(saves, 0);
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

test('pausing cancels the slow-connection warning and resuming starts a fresh display wait', () => {
  state.status = snapshotFixture('connecting');
  state.statusSince = 1000;
  state.connectionSlow = true;
  receiveEngineEvent({ Snapshot: snapshotFixture('paused') }, noop);
  assert.equal(state.connectionSlow, false);
  let renders = 0;
  tickConnection(() => { renders++; }, state.statusSince + CONNECTION_WAIT_MS * 10);
  assert.equal(state.connectionSlow, false);
  assert.equal(renders, 0);

  state.statusSince = 1000;
  receiveEngineEvent({ Snapshot: { ...snapshotFixture('connecting'), videoReceived: true } }, noop);
  assert.ok(state.statusSince > 1000);
  tickConnection(() => { renders++; }, state.statusSince + CONNECTION_WAIT_MS - 1);
  assert.equal(state.connectionSlow, false);
  tickConnection(() => { renders++; }, state.statusSince + CONNECTION_WAIT_MS);
  assert.equal(state.connectionSlow, true);
  assert.equal(renders, 1);
  receiveEngineEvent({ Snapshot: snapshotFixture('mirroring') }, noop);
  assert.equal(state.connectionSlow, false);
  assert.match(renderHTML(), /data-elapsed/);
});

test('a paused initial snapshot never starts a slow-connection warning', async () => {
  window.go.main.App.GetStatus = async () => snapshotFixture('paused');
  await load(noop);
  let renders = 0;
  tickConnection(() => { renders++; }, state.statusSince + CONNECTION_WAIT_MS * 10);
  assert.equal(renders, 0);
  assert.equal(state.connectionSlow, false);
  assert.match(renderHTML(), /Mirroring is paused/);
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

test('pause updates Settings indicators and diagnostics without disturbing edited settings', () => {
  state.route = 'settings';
  state.draft.deviceName = 'An unsaved name';
  let options;
  receiveEngineEvent({ Snapshot: { status: 'paused', backend: 'native' } }, value => { options = value; });
  assert.equal(options.statusOnly, true);
  assert.equal(state.draft.deviceName, 'An unsaved name');
  const elements = {
    '[data-receiver-label]': {},
    '[data-receiver-tone]': { dataset: {} },
    '[data-diagnostic-status]': {},
    '[data-diagnostic-device]': {},
  };
  refreshReceiverStatus({ querySelector: selector => elements[selector] });
  assert.equal(elements['[data-receiver-label]'].textContent, 'Paused');
  assert.equal(elements['[data-receiver-tone]'].dataset.receiverTone, 'neutral');
  assert.equal(elements['[data-diagnostic-status]'].textContent, 'Paused');
  assert.equal(elements['[data-diagnostic-device]'].textContent, 'Your iPhone');
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
  let html = renderHTML();
  assert.match(html, /&lt;preview&gt; &amp; &quot;name&quot;/);
  state.route = 'settings';
  state.logWarning = '<diagnostic>';
  html = renderHTML();
  assert.match(html, /&lt;diagnostic&gt;/);
  assert.doesNotMatch(html, /<preview>|<diagnostic>/);
});

test('details and opt-in logging live only in Settings App', () => {
  for (const status of ['stopped', 'starting', 'needs-setup', 'advertising', 'connecting', 'mirroring', 'paused', 'error']) {
    state.status = { status, backend: 'native' };
    assert.doesNotMatch(renderHTML(), /Connection details|activity-list|Copy details|home-hint/);
  }
  state.route = 'about';
  assert.doesNotMatch(renderHTML(), /data-disclosure=".*-details"|activity-list|Copy details/);
  state.route = 'settings';
  state.settingsSection = 'app';
  state.logsFolder = 'local-logs';
  const html = renderHTML();
  assert.match(html, /Troubleshooting/);
  assert.match(html, /data-disclosure="settings-details"/);
  assert.match(html, /Built into MirrorMe/);
  assert.match(html, /field-verboseLogging/);
  assert.doesNotMatch(html.match(/<input[^>]+id="field-verboseLogging"[^>]*>/)[0], /\bchecked\b/);
  assert.match(html, /local-logs|Open logs folder/);
});

test('logging warnings preserve edited Settings and do not change mirroring state', async () => {
  state.route = 'settings';
  state.settingsSection = 'app';
  state.status = { status: 'mirroring' };
  setDraftField('verboseLogging', true, noop);
  const draft = { ...state.draft };
  let options;
  receiveLogWarning('Disk unavailable', value => { options = value; });
  assert.deepEqual(options, { statusOnly: true });
  assert.deepEqual(state.draft, draft);
  assert.equal(state.status.status, 'mirroring');
  assert.match(renderHTML(), /Disk unavailable/);
  await saveDraft(noop);
  assert.equal(state.settings.verboseLogging, true);
  window.go.main.App.OpenLogsFolder = async () => { throw new Error('Folder unavailable'); };
  await openLogsFolder(noop);
  assert.equal(state.error, 'Folder unavailable');
});

test('the About page explains one tray icon without an extra desktop receiver UI', () => {
  state.route = 'about';
  assert.match(renderHTML(), /One app, one tray icon/);
  assert.doesNotMatch(renderHTML(), /Two tray icons are normal/);
});
