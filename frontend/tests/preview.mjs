// Development fixture only. This file is not an entry point in production.
// No receiver, system settings, clipboard, or real phone is accessed.
import { settingsFixture, snapshotFixture } from './fixtures.mjs';

const params = new URLSearchParams(location.search);
let settings = {
  ...settingsFixture,
  firstRun: params.get('onboarding') === '1',
  theme: params.get('theme') || 'light',
  deviceName: params.get('name') || settingsFixture.deviceName,
  requirePin: params.get('pin') === '1',
  pinCode: params.get('pin') === '1' ? '2468' : '',
};
function receiverSnapshot(status) {
  return { ...snapshotFixture(status), backend: params.get('backend') === 'native' ? 'native' : 'legacy' };
}
let snapshot = receiverSnapshot(params.get('state') || (settings.firstRun && params.get('step') !== '2' ? 'stopped' : 'advertising'));
if (params.get('video') === '1') snapshot.videoReceived = true;
if (params.get('download') === '1') {
  snapshot.setupKind = 'runtime';
  snapshot.setupProgress = 42;
}
const listeners = new Map();
const calls = [];
let command = 0;
let maximised = false;

function emit(name, event) {
  for (const callback of listeners.get(name) || []) callback(event);
}

function setStatus(status) {
  snapshot = receiverSnapshot(status);
  emit('engine-status', { Snapshot: snapshot, Activity: `Preview: ${status}` });
}

window.go = { main: { App: {
  GetSettings: async () => structuredClone(settings),
  GetStatus: async () => structuredClone(snapshot),
  GetVersion: async () => 'UI preview',
  GetSettingsFolder: async () => 'Preview only - no files are changed',
  GetLogsFolder: async () => 'Preview only - no log files are created',
  SaveSettings: async next => {
    calls.push(['save', structuredClone(next)]);
    settings = { ...next, deviceName: next.deviceName.trim() };
    if (settings.requirePin && !settings.pinCode) settings.pinCode = '2468';
    if (!settings.requirePin) settings.pinCode = '';
    emit('settings-updated', structuredClone(settings));
    return structuredClone(settings);
  },
  RegeneratePinCode: async () => {
    settings = { ...settings, pinCode: settings.pinCode === '2468' ? '1357' : '2468' };
    emit('settings-updated', structuredClone(settings));
    return structuredClone(settings);
  },
  StartMirroring: async () => {
    calls.push(['start']);
    const current = ++command;
    setStatus('starting');
    setTimeout(() => { if (current === command) setStatus('advertising'); }, 300);
  },
  StopMirroring: async () => {
    calls.push(['stop']);
    command++;
    setStatus('stopped');
  },
  ConfirmSetupAndStart: async () => {
    calls.push(['setup']);
    setStatus('advertising');
  },
  ShowMirroredScreen: async () => snapshot.status === 'mirroring',
  OpenSettingsFolder: async () => { calls.push(['open-folder']); },
  OpenLogsFolder: async () => { calls.push(['open-logs-folder']); },
  OpenExternalURL: async url => { calls.push(['open-url', url]); },
  Quit: async () => { calls.push(['quit']); },
} } };

window.runtime = {
  EventsOnMultiple(name, callback) {
    if (!listeners.has(name)) listeners.set(name, []);
    listeners.get(name).push(callback);
    return () => listeners.set(name, listeners.get(name).filter(item => item !== callback));
  },
  WindowIsMaximised: async () => maximised,
  WindowToggleMaximise: () => { maximised = !maximised; },
  WindowMinimise: () => { calls.push(['minimise']); },
  WindowHide: () => { calls.push(['hide']); },
  WindowSetDarkTheme: () => { calls.push(['native-theme', 'dark']); },
  WindowSetLightTheme: () => { calls.push(['native-theme', 'light']); },
  WindowSetSystemDefaultTheme: () => { calls.push(['native-theme', 'system']); },
  ClipboardSetText: async text => { calls.push(['clipboard', text]); return true; },
};

const { state } = await import('../src/state.js');
state.route = ['home', 'settings', 'about'].includes(params.get('route')) ? params.get('route') : 'home';
state.settingsSection = ['connection', 'picture', 'app'].includes(params.get('section')) ? params.get('section') : 'connection';
state.setupStep = params.get('step') === '2' ? 2 : 1;
const { render } = await import('../src/main.js');
window.__mirrorMePreview = { state, setStatus, render, calls, emit };
if (params.get('slow') === '1') {
  const pending = setInterval(() => {
    if (state.loading) return;
    clearInterval(pending);
    state.statusSince = Date.now() - 13000;
  }, 20);
}
