import { initialState, reduce } from './demo.mjs';

const root = document.querySelector('#demo');
const desk = document.querySelector('#preview-desk');
const frame = document.querySelector('#app-preview');
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const systemTheme = matchMedia('(prefers-color-scheme: dark)');
const motion = document.querySelector('#motion');
const channel = 'mirrorme-website-preview';
let state = initialState(reduced.matches);
let explicitTheme = false;
let appReady = false;
let loadDeadline;

function send(message) {
  if (appReady) frame.contentWindow.postMessage({ channel, ...message }, location.origin);
}

function theme(dark) {
  const mode = dark ? 'dark' : 'light';
  document.documentElement.dataset.mode = mode;
  document.querySelector('#theme').setAttribute('aria-label', `Use ${dark ? 'light' : 'dark'} theme`);
  document.querySelector('#theme use').setAttribute('href', dark ? '#i-sun' : '#i-moon');
  send({ type: 'theme', mode });
}

function render() {
  root.dataset.phase = state.phase;
  root.dataset.motion = String(state.motion);
  root.dataset.landscape = String(state.landscape);
  const visible = state.phase === 'mirroring' && !state.videoMinimised;
  document.querySelector('#video-window').hidden = !visible;
  document.querySelector('#video-placeholder').hidden = visible;
  document.querySelector('#video-placeholder-text').textContent = state.videoMinimised
    ? 'The video window is minimized. The example is still mirroring.'
    : state.phase === 'advertising' ? 'The receiver is ready. Reconnect the example iPhone to show video again.'
      : 'The example session has stopped. Reconnect the example to explore it again.';
  document.querySelector('#restore-video').textContent = state.videoMinimised ? 'Show video' : 'Reconnect example';
  document.querySelector('#rotate').setAttribute('aria-pressed', String(state.landscape));
  motion.checked = state.motion;
}

function dispatch(event) {
  state = reduce(state, event);
  render();
}

function showVideo() {
  dispatch({ type: 'show-video' });
  const video = document.querySelector('#video-window');
  video.scrollIntoView({ block: 'nearest', behavior: reduced.matches ? 'instant' : 'smooth' });
  video.focus({ preventScroll: true });
}

function showApp() {
  frame.hidden = false;
  document.querySelector('#app-placeholder').hidden = true;
}

function failPreview() {
  clearTimeout(loadDeadline);
  appReady = false;
  root.dataset.ready = 'error';
  document.querySelector('#preview-error').hidden = false;
}

window.addEventListener('message', event => {
  if (event.source !== frame.contentWindow || event.origin !== location.origin || event.data?.channel !== channel) return;
  const message = event.data;
  switch (message.type) {
    case 'ready':
      appReady = true;
      clearTimeout(loadDeadline);
      document.querySelector('#preview-error').hidden = true;
      root.dataset.ready = 'true';
      if (['mirroring', 'advertising', 'stopped'].includes(message.status)) dispatch({ type: 'status', value: message.status });
      send({ type: 'theme', mode: document.documentElement.dataset.mode });
      break;
    case 'error': failPreview(); break;
    case 'status':
      if (['mirroring', 'advertising', 'stopped'].includes(message.status)) dispatch({ type: 'status', value: message.status });
      break;
    case 'window':
      if (message.action === 'show-video') showVideo();
      else if (message.action === 'show-app') showApp();
      else if (['hide', 'minimise', 'quit'].includes(message.action)) {
        frame.hidden = true;
        document.querySelector('#app-placeholder').hidden = false;
        document.querySelector('#app-placeholder-text').textContent = message.action === 'quit'
          ? 'The example app is closed. You can reopen it without leaving this page.'
          : message.action === 'minimise' ? 'MirrorMe is minimized. The separate video window stays open.'
            : 'MirrorMe is in the system tray. The separate video window stays open.';
        document.querySelector('#restore-app').focus({ preventScroll: true });
      } else if (message.action === 'maximise' || message.action === 'restore') {
        desk.dataset.appExpanded = String(message.action === 'maximise');
      }
      break;
  }
});

frame.addEventListener('error', failPreview);
const greetPreview = () => frame.contentWindow.postMessage({ channel, type: 'hello' }, location.origin);
frame.addEventListener('load', greetPreview);
document.querySelector('#reload-preview').addEventListener('click', () => {
  document.querySelector('#preview-error').hidden = true;
  appReady = false;
  root.dataset.ready = 'false';
  frame.src = new URL('./preview/index.html', location.href).href;
  clearTimeout(loadDeadline);
  loadDeadline = setTimeout(failPreview, 15000);
  greetPreview();
});
document.querySelector('#rotate').addEventListener('click', () => dispatch({ type: 'rotate' }));
motion.addEventListener('change', () => dispatch({ type: 'motion', value: motion.checked }));
document.querySelector('#minimise-video').addEventListener('click', () => {
  dispatch({ type: 'minimise-video' });
  document.querySelector('#restore-video').focus({ preventScroll: true });
});
document.querySelector('#maximise-video').addEventListener('click', event => {
  const expanded = desk.dataset.videoExpanded !== 'true';
  desk.dataset.videoExpanded = String(expanded);
  event.currentTarget.setAttribute('aria-pressed', String(expanded));
  event.currentTarget.setAttribute('aria-label', `${expanded ? 'Restore' : 'Maximize'} example video window`);
});
document.querySelector('#close-video').addEventListener('click', () => {
  send({ type: 'close-video' });
  dispatch({ type: 'status', value: 'advertising' });
  document.querySelector('#restore-video').focus({ preventScroll: true });
});
document.querySelector('#restore-video').addEventListener('click', () => {
  if (state.phase !== 'mirroring') {
    if (!appReady) { failPreview(); return; }
    send({ type: 'connect' });
  } else showVideo();
});
document.querySelector('#restore-app').addEventListener('click', () => {
  showApp();
  frame.focus();
});
document.querySelector('#reset').addEventListener('click', () => {
  state = initialState(reduced.matches);
  showApp();
  desk.dataset.appExpanded = desk.dataset.videoExpanded = 'false';
  document.querySelector('#maximise-video').setAttribute('aria-pressed', 'false');
  document.querySelector('#maximise-video').setAttribute('aria-label', 'Maximize example video window');
  send({ type: 'reset', mode: document.documentElement.dataset.mode });
  render();
});
document.querySelector('#theme').addEventListener('click', () => {
  explicitTheme = true;
  theme(document.documentElement.dataset.mode !== 'dark');
});
reduced.addEventListener('change', event => { if (event.matches) dispatch({ type: 'motion', value: false }); });
systemTheme.addEventListener('change', event => { if (!explicitTheme) theme(event.matches); });
theme(systemTheme.matches);
render();
loadDeadline = setTimeout(failPreview, 15000);
