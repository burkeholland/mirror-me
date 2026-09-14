import {
  state, load, navigate, selectSettingsSection, openPictureSettings, setDraftField,
  revertDraft, saveDraft, regeneratePin, beginSetup, dismissFirstRun,
  startMirroring, stopMirroring, confirmSetupAndStart, showMirroredScreen,
  openSettingsFolder, openLogsFolder, copyLogsPath, copySettingsFolder, copyDeviceName, copyDiagnostics,
  openExternalURL, minimiseWindow, toggleMaximiseWindow, hideWindow, quitApp,
  openDialog, closeDialog, finishNavigation, dismissToast,
} from './state.js';
import { refreshSaveBar } from './render.js';
import { applyTheme } from './theme.js';

const NUMERIC_FIELDS = new Set(['maxFps', 'idleTimeoutSeconds']);
const boundApps = new WeakSet();

export function bindEvents(app, render) {
  if (boundApps.has(app)) return;
  boundApps.add(app);
  // Delegate to the stable root so replacing a view never duplicates listeners.
  app.addEventListener('click', async event => {
    const control = event.target.closest?.('[data-action], [data-waction]');
    if (!control || control.disabled) return;
    event.preventDefault();
    switch (control.dataset.waction) {
      case 'minimise': minimiseWindow(); return;
      case 'maximise': toggleMaximiseWindow(render); return;
      case 'hide': hideWindow(); return;
    }
    switch (control.dataset.action) {
      case 'nav-home': navigate('home', render); break;
      case 'nav-settings': navigate('settings', render); break;
      case 'nav-about': navigate('about', render); break;
      case 'settings-section': selectSettingsSection(control.dataset.section, render); break;
      case 'picture-settings': openPictureSettings(render); break;
      case 'start-mirroring': await startMirroring(render); break;
      case 'stop-mirroring': await stopMirroring(render); break;
      case 'show-mirrored-screen': await showMirroredScreen(render); break;
      case 'confirm-setup': await confirmSetupAndStart(render); break;
      case 'setup-back': state.setupStep = 1; state.focusTarget = 'setup-name'; render(); break;
      case 'dismiss-first-run': await dismissFirstRun(render); break;
      case 'save-settings': await saveDraft(render); break;
      case 'revert-settings': revertDraft(render); break;
      case 'regenerate-pin': await regeneratePin(render); break;
      case 'copy-device-name': await copyDeviceName(render); break;
      case 'copy-diagnostics': await copyDiagnostics(render); break;
      case 'copy-settings-folder': await copySettingsFolder(render); break;
      case 'open-settings-folder': await openSettingsFolder(render); break;
      case 'open-guide': openDialog('guide', render); break;
      case 'close-dialog': closeDialog(render); break;
      case 'save-and-leave': await finishNavigation(true, render); break;
      case 'discard-and-leave': await finishNavigation(false, render); break;
      case 'dismiss-toast': dismissToast(Number(control.dataset.toastId), render); break;
      case 'reload': await load(render); break;
      case 'open-link': await openExternalURL(control.dataset.url, render); break;
      case 'quit': await quitApp(render); break;
      case 'open-logs-folder': await openLogsFolder(render); break;
      case 'copy-logs-path': await copyLogsPath(render); break;
    }
  });

  app.addEventListener('submit', event => {
    if (event.target.id === 'setup-form') {
      event.preventDefault();
      beginSetup(render);
    }
  });

  const updateField = event => {
    const field = event.target;
    if (field.id === 'setup-name') {
      state.setupName = field.value;
      setDraftField('deviceName', field.value, () => refreshSaveBar(app));
      return;
    }
    if (!field.dataset.field) return;
    const value = field.type === 'checkbox' ? field.checked
      : NUMERIC_FIELDS.has(field.dataset.field) ? Number(field.value) : field.value;
    setDraftField(field.dataset.field, value, () => {
      if (field.dataset.field === 'requirePin') render();
      else refreshSaveBar(app);
      if (field.dataset.field === 'theme') applyTheme(value, true);
    });
  };
  app.addEventListener('input', event => {
    if (event.target.tagName === 'INPUT' && event.target.type !== 'checkbox') updateField(event);
  });
  app.addEventListener('change', event => {
    if (event.target.tagName === 'SELECT' || event.target.type === 'checkbox') updateField(event);
  });
  app.addEventListener('toggle', event => {
    const key = event.target.dataset.disclosure;
    if (key) state.details[key] = event.target.open;
  }, true);
  app.addEventListener('cancel', event => {
    if (event.target.tagName === 'DIALOG') {
      event.preventDefault();
      closeDialog(render);
    }
  }, true);
  app.addEventListener('keydown', event => {
    const tab = event.target.closest?.('[role="tab"]');
    if (!tab || !['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    const tabs = [...app.querySelectorAll('[role="tab"]')];
    const index = tabs.indexOf(tab);
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1
      : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
    selectSettingsSection(tabs[next].dataset.section, render);
  });
}

export function bindShortcuts(target, render) {
  target.addEventListener('keydown', event => {
    if (event.altKey || event.shiftKey) return;
    if (event.key === 'F1') {
      event.preventDefault();
      if (!state.dialog) openDialog('guide', render);
      return;
    }
    if (event.ctrlKey && event.key.toLowerCase() === 's') {
      event.preventDefault();
      if (!state.dialog && state.route === 'settings') saveDraft(render);
      return;
    }
    if (state.dialog) return;
    if (event.ctrlKey && event.key === ',') {
      event.preventDefault();
      navigate('settings', render);
    }
  });
}
