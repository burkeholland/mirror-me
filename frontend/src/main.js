import './vendor/postrboard.css';
import './style.css';
import {
  state, load, receiveEngineEvent, receiveSettingsUpdate, receiveLogWarning, navigate, tickConnection, syncWindowState,
} from './state.js';
import { renderApp, refreshToasts, refreshReceiverStatus, refreshWindowControls, refreshElapsed } from './render.js';
import { bindEvents, bindShortcuts } from './events.js';
import { applyTheme } from './theme.js';
import { EventsOn } from '../wailsjs/runtime/runtime';

const app = document.querySelector('#app');
const selectedTheme = () => (state.route === 'settings' ? state.draft?.theme : state.settings?.theme) ?? 'system';

export function render(options = {}) {
  if (options.transient) refreshToasts(app);
  else if (options.statusOnly) refreshReceiverStatus(app);
  else if (options.windowOnly) refreshWindowControls(app);
  else {
    applyTheme(selectedTheme(), Boolean(state.settings));
    renderApp(app);
  }
}

bindEvents(app, render);
bindShortcuts(document, render);
render();
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => applyTheme(selectedTheme(), Boolean(state.settings)));

// Subscribe before the initial requests: live status always wins over a slow snapshot.
EventsOn('engine-status', event => receiveEngineEvent(event, render));
EventsOn('settings-updated', settings => receiveSettingsUpdate(settings, render));
EventsOn('log-warning', message => receiveLogWarning(message, render));
EventsOn('navigate', route => navigate(route, render));
load(render);

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => syncWindowState(render), 150);
});
setInterval(() => {
  tickConnection(render);
  refreshElapsed(app);
}, 1000);
