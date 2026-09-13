import { initialState, reduce, formatTime } from './demo.mjs';

const root = document.querySelector('#demo');
const reduced = matchMedia('(prefers-reduced-motion: reduce)');
const systemTheme = matchMedia('(prefers-color-scheme: dark)');
const connect = document.querySelector('#connect');
const motion = document.querySelector('#motion');
const note = document.querySelector('#demo-note');
let state = initialState(reduced.matches);
let connectionTimer;
let explicitTheme = false;

function theme(dark) {
  document.documentElement.dataset.mode = dark ? 'dark' : 'light';
  document.querySelector('#theme').setAttribute('aria-label', `Use ${dark ? 'light' : 'dark'} theme`);
  document.querySelector('#theme use').setAttribute('href', dark ? '#i-sun' : '#i-moon');
}

function render() {
  root.dataset.phase = state.phase;
  root.dataset.content = state.content;
  root.dataset.playing = String(state.playing);
  root.dataset.landscape = String(state.landscape);
  for (const element of root.querySelectorAll('.sample')) element.hidden = !element.classList.contains(state.content);
  for (const button of root.querySelectorAll('button[data-content]')) button.setAttribute('aria-pressed', String(button.dataset.content === state.content));
  const connected = state.phase === 'mirroring';
  document.querySelector('#mirrored-screen').hidden = !connected;
  document.querySelector('#empty-screen').hidden = connected;
  document.querySelector('#display-title').textContent = state.phase === 'connecting' ? 'Making a little room...' : 'Ready for your iPhone';
  document.querySelector('#display-description').textContent = state.phase === 'connecting' ? 'Connecting the example screens.\nNo actual device is being accessed.' : 'Your screen goes here.\nStart the demo to see it in action.';
  document.querySelector('#demo-status').textContent = connected ? 'Mirroring the example' : state.phase === 'connecting' ? 'Connecting the example' : 'Ready to try';
  document.querySelector('[data-sidebar-status]').textContent = connected ? 'Mirroring' : state.phase === 'connecting' ? 'Connecting' : 'Ready to connect';
  connect.querySelector('span').textContent = connected ? 'Stop demo' : state.phase === 'connecting' ? 'Cancel' : 'Start demo';
  connect.querySelector('use').setAttribute('href', state.phase === 'idle' ? '#i-play' : '#i-pause');
  document.querySelector('#rotate').setAttribute('aria-pressed', String(state.landscape));
  motion.setAttribute('aria-pressed', String(state.playing));
  motion.querySelector('span').textContent = state.playing ? 'Pause animation' : 'Play animation';
  motion.querySelector('use').setAttribute('href', state.playing ? '#i-pause' : '#i-play');
  document.querySelector('#note-editor').hidden = state.content !== 'notes';
  if (note.value !== state.note) note.value = state.note;
  for (const element of root.querySelectorAll('[data-note]')) element.textContent = state.note;
  renderClock();
  document.querySelector('#interaction-hint').textContent = state.content === 'notes' ? 'Edit the note below the controls. Both example screens update together.' : state.content === 'clock' ? 'Pause the animation to hold the example stopwatch.' : 'Try a different screen, or rotate the phone.';
}

function renderClock() {
  for (const element of root.querySelectorAll('[data-clock]')) element.textContent = formatTime(state.seconds);
}

function dispatch(event) {
  state = reduce(state, event);
  render();
}

connect.addEventListener('click', () => {
  clearTimeout(connectionTimer);
  if (state.phase !== 'idle') {
    dispatch({ type: 'stop' });
    return;
  }
  dispatch({ type: 'start' });
  connectionTimer = setTimeout(() => dispatch({ type: 'connected' }), reduced.matches ? 250 : 1100);
});
for (const button of root.querySelectorAll('button[data-content]')) button.addEventListener('click', () => dispatch({ type: 'content', value: button.dataset.content }));
document.querySelector('#rotate').addEventListener('click', () => dispatch({ type: 'rotate' }));
motion.addEventListener('click', () => dispatch({ type: 'motion' }));
note.addEventListener('input', () => dispatch({ type: 'note', value: note.value }));
document.querySelector('#reset').addEventListener('click', () => {
  clearTimeout(connectionTimer);
  state = initialState(reduced.matches);
  render();
});
document.querySelector('#theme').addEventListener('click', () => {
  explicitTheme = true;
  theme(document.documentElement.dataset.mode !== 'dark');
});
reduced.addEventListener('change', event => { if (event.matches) dispatch({ type: 'pause' }); });
systemTheme.addEventListener('change', event => { if (!explicitTheme) theme(event.matches); });
setInterval(() => {
  if (document.hidden || !state.playing) return;
  state = reduce(state, { type: 'tick' });
  renderClock();
}, 1000);
theme(systemTheme.matches);
render();
root.dataset.ready = 'true';
