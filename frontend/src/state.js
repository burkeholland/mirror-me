import {
  GetSettings, SaveSettings, RegeneratePinCode, GetStatus, StartMirroring,
  StopMirroring, ConfirmSetupAndStart, ShowMirroredScreen, GetVersion,
  GetSettingsFolder, OpenSettingsFolder, GetLogsFolder, OpenLogsFolder, OpenExternalURL, Quit,
} from '../wailsjs/go/main/App';
import {
  WindowToggleMaximise, WindowIsMaximised, WindowMinimise, WindowHide, ClipboardSetText,
} from '../wailsjs/runtime/runtime';
import { friendlyErrorMessage, deviceLabel, MAX_PC_NAME_BYTES } from './format.js';

export const CONNECTION_WAIT_MS = 12000;
export const state = {
  settings: null,
  draft: null,
  version: '',
  settingsFolder: '',
  logsFolder: '',
  logWarning: '',
  status: { status: 'stopped' },
  statusSince: 0,
  connectionSlow: false,
  route: 'home',
  settingsSection: 'connection',
  setupStep: 1,
  setupName: '',
  details: {},
  scrollPositions: {},
  dialog: null,
  returnFocus: '',
  focusTarget: '',
  toasts: [],
  error: '',
  fieldError: '',
  loading: true,
  saving: false,
  busy: false,
  busyAction: '',
  maximised: false,
};

let nextToastId = 1;
let engineEventRevision = 0;
let settingsEventRevision = 0;
let commandRevision = 0;

export function clone(value) { return JSON.parse(JSON.stringify(value)); }

function persisted(settings) {
  if (!settings) return null;
  const { loadError, logWarning, ...rest } = settings;
  return rest;
}

export function hasDraftChanges() {
  return state.draft !== null
    && JSON.stringify(persisted(state.draft)) !== JSON.stringify(persisted(state.settings));
}

function acceptSettings(settings, preserveDraft = true) {
  // Rebase only edited fields. Background updates must neither erase edits nor
  // make untouched, stale fields look like new changes.
  const edits = preserveDraft && state.draft && state.settings
    ? Object.fromEntries(Object.entries(persisted(state.draft))
      .filter(([key, value]) => value !== state.settings[key]))
    : {};
  state.settings = settings;
  state.logWarning = settings.logWarning || '';
  state.draft = { ...clone(settings), ...edits };
  state.setupName = state.draft.deviceName;
}

function acceptSnapshot(snapshot) {
  if (!state.statusSince || snapshot.status !== state.status.status
    || snapshot.deviceName !== state.status.deviceName
    || Boolean(snapshot.videoReceived) !== Boolean(state.status.videoReceived)) {
    state.statusSince = Date.now();
    state.connectionSlow = false;
  }
  if (snapshot.status !== 'connecting') state.connectionSlow = false;
  state.status = snapshot;
}

export function clearError() {
  state.error = '';
  state.fieldError = '';
}

function setError(error, render) {
  state.error = friendlyErrorMessage(error);
  render();
}

export function pushToast(message, tone, render) {
  const id = nextToastId++;
  state.toasts = [...state.toasts.slice(-2), { id, message, tone: tone ?? 'info' }];
  render({ transient: true });
  const timer = setTimeout(() => dismissToast(id, render), 4500);
  timer.unref?.();
}

export function dismissToast(id, render) {
  state.toasts = state.toasts.filter(toast => toast.id !== id);
  render({ transient: true });
}

export async function load(render) {
  const engineRevisionAtLoad = engineEventRevision;
  const settingsRevisionAtLoad = settingsEventRevision;
  state.loading = true;
  clearError();
  render();
  try {
    const [settings, version, status, settingsFolder, logsFolder, maximised] = await Promise.all([
      GetSettings(), GetVersion(), GetStatus(), GetSettingsFolder(), GetLogsFolder(), WindowIsMaximised(),
    ]);
    if (settingsEventRevision === settingsRevisionAtLoad) acceptSettings(settings);
    if (engineEventRevision === engineRevisionAtLoad) acceptSnapshot(status);
    state.version = version;
    state.settingsFolder = settingsFolder;
    state.logsFolder = logsFolder;
    state.maximised = maximised;
    state.setupName = state.draft.deviceName;
    state.error = state.settings.loadError || '';
  } catch (error) {
    state.error = friendlyErrorMessage(error);
  } finally {
    state.loading = false;
    render();
  }
}

export function receiveEngineEvent(event, render) {
  engineEventRevision++;
  const changed = event.Snapshot && JSON.stringify(event.Snapshot) !== JSON.stringify(state.status);
  if (event.Snapshot) acceptSnapshot(event.Snapshot);
  // In Settings, update the receiver indicator without interrupting typing,
  // keyboard focus, or an open native select menu.
  render({ statusOnly: state.route !== 'home' || !changed });
}

export function receiveSettingsUpdate(settings, render) {
  settingsEventRevision++;
  acceptSettings(settings);
  render();
}

export function receiveLogWarning(message, render) {
  state.logWarning = String(message || '');
  render({ statusOnly: true });
}

export function tickConnection(render, now = Date.now()) {
  if (state.status.status === 'connecting' && !state.connectionSlow
    && state.statusSince && now - state.statusSince >= CONNECTION_WAIT_MS) {
    state.connectionSlow = true;
    render({ statusOnly: state.route !== 'home' });
  }
}

export function openDialog(kind, render, target = '') {
  if (kind === 'guide' && !state.settings) {
    pushToast(state.loading ? 'MirrorMe is still opening.' : 'Choose Try again to load your settings before opening the guide.', 'info', render);
    return;
  }
  state.dialog = { kind, target };
  state.returnFocus = globalThis.document?.activeElement?.id || '';
  state.focusTarget = kind === 'unsaved' ? 'dialog-cancel' : 'dialog-close';
  render();
}

export function closeDialog(render) {
  if (state.saving) return;
  state.dialog = null;
  state.focusTarget = state.returnFocus;
  state.returnFocus = '';
  render();
}

export function navigate(route, render) {
  if (state.route === route) return;
  if (hasDraftChanges()) {
    openDialog('unsaved', render, route);
    return;
  }
  state.route = route;
  state.dialog = null;
  state.focusTarget = 'page-title';
  render();
}

export function selectSettingsSection(section, render) {
  state.settingsSection = section;
  state.focusTarget = `tab-${section}`;
  render();
}

export function openPictureSettings(render) {
  state.settingsSection = 'picture';
  navigate('settings', render);
}

export function setDraftField(field, value, render) {
  if (state.saving || !state.draft) return;
  clearError();
  state.draft = { ...state.draft, [field]: value };
  render();
}

export function revertDraft(render) {
  if (state.saving) return;
  clearError();
  acceptSettings(state.settings, false);
  render();
}

function validateName(name) {
  if (!name.trim()) {
    state.fieldError = 'Give this PC a name so you can find it on your iPhone.';
    return false;
  }
  if (new TextEncoder().encode(name.trim()).length > MAX_PC_NAME_BYTES) {
    state.fieldError = 'Use a shorter PC name so it fits in Screen Mirroring.';
    return false;
  }
  if (/[\u0000-\u001f\u007f]/.test(name)) {
    state.fieldError = 'Use a PC name without control characters.';
    return false;
  }
  return true;
}

export async function saveDraft(render) {
  if (state.saving) return false;
  if (!hasDraftChanges()) return true;
  clearError();
  if (!validateName(state.draft.deviceName)) {
    state.settingsSection = 'connection';
    state.focusTarget = state.settings.firstRun && state.route === 'home' ? 'setup-name' : 'field-deviceName';
    render();
    return false;
  }
  state.saving = true;
  render();
  try {
    const saved = await SaveSettings(clone(state.draft));
    acceptSettings(saved, false);
    pushToast('Settings saved', 'success', render);
    return true;
  } catch (error) {
    state.error = friendlyErrorMessage(error);
    return false;
  } finally {
    state.saving = false;
    render();
  }
}

export async function finishNavigation(save, render) {
  const target = state.dialog?.target;
  if (!target || state.saving) return;
  if (save && !await saveDraft(render)) return;
  if (!save) revertDraft(() => {});
  state.dialog = null;
  state.returnFocus = '';
  state.route = target;
  state.focusTarget = 'page-title';
  render();
}

export async function regeneratePin(render) {
  if (state.saving) return;
  clearError();
  state.saving = true;
  render();
  try {
    acceptSettings(await RegeneratePinCode());
    pushToast('New pairing code generated', 'success', render);
  } catch (error) {
    state.error = friendlyErrorMessage(error);
  } finally {
    state.saving = false;
    render();
  }
}

export async function beginSetup(render) {
  if (state.saving || state.busy) return;
  clearError();
  if (!validateName(state.setupName)) {
    state.focusTarget = 'setup-name';
    render();
    return;
  }
  state.saving = true;
  render();
  try {
    const saved = await SaveSettings({ ...clone(state.settings), deviceName: state.setupName.trim() });
    acceptSettings(saved, false);
    state.setupName = saved.deviceName;
    state.setupStep = 2;
    state.focusTarget = 'page-title';
  } catch (error) {
    state.error = friendlyErrorMessage(error);
    return;
  } finally {
    state.saving = false;
    render();
  }
  if (['stopped', 'error'].includes(state.status.status)) await startMirroring(render);
}

export async function dismissFirstRun(render) {
  if (state.saving) return;
  clearError();
  state.saving = true;
  render();
  try {
    acceptSettings(await SaveSettings({ ...clone(state.settings), firstRun: false }), false);
    state.focusTarget = 'page-title';
  } catch (error) {
    state.error = friendlyErrorMessage(error);
  } finally {
    state.saving = false;
    render();
  }
}

async function receiverCommand(action, command, render) {
  if (state.busy && (action !== 'stop' || state.busyAction === 'stop')) return;
  const revision = ++commandRevision;
  clearError();
  state.busy = true;
  state.busyAction = action;
  render();
  try {
    await command();
  } catch (error) {
    if (revision === commandRevision) state.error = friendlyErrorMessage(error);
  } finally {
    // Cancel can supersede a pending start or setup request.
    if (revision === commandRevision) {
      state.busy = false;
      state.busyAction = '';
      render();
    }
  }
}

export const startMirroring = render => receiverCommand('start', StartMirroring, render);
export const stopMirroring = render => receiverCommand('stop', StopMirroring, render);
export const confirmSetupAndStart = render => receiverCommand('setup', ConfirmSetupAndStart, render);

export async function showMirroredScreen(render) {
  if (state.status.status === 'paused') return;
  clearError();
  try {
    if (!await ShowMirroredScreen()) {
      pushToast('The video window is not available yet. Try reconnecting from your iPhone.', 'warning', render);
    }
  } catch (error) {
    setError(error, render);
  }
}

export async function openSettingsFolder(render) {
  try { await OpenSettingsFolder(); } catch (error) { setError(error, render); }
}

export async function openLogsFolder(render) {
  try { await OpenLogsFolder(); } catch (error) { setError(error, render); }
}

async function copyText(text, message, render) {
  try {
    if (!await ClipboardSetText(text)) throw new Error('Windows could not copy to the clipboard. Try again.');
    pushToast(message, 'success', render);
  } catch (error) {
    setError(error, render);
  }
}

export const copySettingsFolder = render => copyText(state.settingsFolder, 'Settings path copied', render);
export const copyDeviceName = render => copyText(state.settings.deviceName, 'PC name copied', render);
export const copyLogsPath = render => copyText(state.logsFolder, 'Logs path copied', render);

export function diagnosticText() {
  const snapshot = state.status;
  return [
    `MirrorMe ${state.version}`,
    `Receiver: ${snapshot.status}`,
    `Device: ${deviceLabel(snapshot)}`,
    `Model: ${snapshot.deviceModel || 'Unknown'}`,
    `Video: ${snapshot.status === 'paused' ? 'Paused, not displayed' : snapshot.status === 'mirroring' ? 'Displayed' : snapshot.videoReceived ? 'Received, not displayed' : 'Not received'}`,
    `Error: ${snapshot.lastError || 'None'}`,
  ].join('\n');
}

export const copyDiagnostics = render => copyText(diagnosticText(), 'Connection details copied', render);

export async function openExternalURL(url, render) {
  try { await OpenExternalURL(url); } catch (error) { setError(error, render); }
}

export function minimiseWindow() { WindowMinimise(); }
export function hideWindow() { WindowHide(); }

export async function syncWindowState(render) {
  try {
    const maximised = await WindowIsMaximised();
    if (state.maximised !== maximised) {
      state.maximised = maximised;
      render({ windowOnly: true });
    }
  } catch (error) {
    setError(error, render);
  }
}

export function toggleMaximiseWindow(render) {
  WindowToggleMaximise();
  setTimeout(() => syncWindowState(render), 100);
}

export async function quitApp(render) {
  try { await Quit(); } catch (error) { setError(error, render); }
}
