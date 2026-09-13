import { createPreviewBridge } from './bridge.mjs';

const channel = 'mirrorme-website-preview';
const notify = message => {
  if (parent !== window) parent.postMessage({ channel, ...message }, location.origin);
};
const bridge = createPreviewBridge({
  notify,
  theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
});
window.go = { main: { App: bridge.app } };
window.runtime = bridge.runtime;

try {
  const { render } = await import('../src/main.js');
  const { state } = await import('../src/state.js');
  const announce = async () => notify({ type: 'ready', status: (await bridge.app.GetStatus()).status });
  window.addEventListener('message', event => {
    if (event.source !== parent || event.origin !== location.origin || event.data?.channel !== channel) return;
    switch (event.data.type) {
      case 'hello': announce(); break;
      case 'theme':
        if (['light', 'dark'].includes(event.data.mode)) bridge.setTheme(event.data.mode);
        break;
      case 'connect': bridge.connect(); break;
      case 'close-video': bridge.closeVideo(); break;
      case 'reset':
        if (!['light', 'dark'].includes(event.data.mode)) break;
        Object.assign(state, {
          route: 'home', settingsSection: 'connection', dialog: null, focusTarget: '',
          returnFocus: '', details: {}, scrollPositions: {}, activity: [], toasts: [],
          error: '', fieldError: '', draft: null, maximised: false,
        });
        bridge.reset(event.data.mode);
        render();
        break;
    }
  });
  document.documentElement.dataset.previewReady = 'true';
  await announce();
} catch (error) {
  console.error('The app preview could not open.', error);
  document.querySelector('#app').textContent = 'The app preview could not open. Reload the page to try again.';
  notify({ type: 'error' });
}
