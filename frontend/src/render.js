import { state, hasDraftChanges } from './state.js';
import { escHtml, escAttr, statusMeta, formatElapsedSince, resolutionLabel, deviceLabel, MAX_PC_NAME_BYTES } from './format.js';
import { icon } from './icons.js';

const SECTIONS = [['connection', 'Connection'], ['picture', 'Picture & sound'], ['app', 'App']];
const RESOLUTIONS = ['auto', '1280x720', '1920x1080', '3840x2160'];
const FPS = [[0, 'Automatic'], [30, '30 fps'], [60, '60 fps'], [120, '120 fps']];
const IDLE = [[0, 'Never'], [15, '15 seconds'], [30, '30 seconds'], [60, '1 minute'], [300, '5 minutes']];
const THEMES = [['system', 'Follow Windows'], ['light', 'Light'], ['dark', 'Dark']];
let suspendedFocus = null;

function button(action, label, options = {}) {
  const kind = options.primary ? 'primary' : options.quiet ? 'ghost' : 'secondary';
  return `<button type="button" class="btn btn-${kind}${options.small ? ' btn-sm' : ''}"
    id="${options.id || `action-${action}`}" data-action="${action}" ${options.disabled ? 'disabled' : ''}
    ${options.attrs || ''}>${options.icon ? icon(options.icon) : ''}<span>${label}</span></button>`;
}

function errorNotice() {
  return state.error ? `<div class="notice notice-error" data-app-error role="alert">${icon('alert')}
    <p>${escHtml(state.error)}</p></div>` : '';
}

function heading(title, subtitle = '', action = '') {
  return `<header class="page-header"><div><h1 id="page-title" tabindex="-1">${title}</h1>
    ${subtitle ? `<p>${subtitle}</p>` : ''}</div>${action}</header>`;
}

function disclosure(key, title, content, className = '') {
  return `<details class="disclosure ${className}" data-disclosure="${key}" ${state.details[key] ? 'open' : ''}>
    <summary id="disclosure-${key}"><span>${title}</span>${icon('chevron')}</summary>
    <div class="disclosure-content">${content}</div></details>`;
}

export function renderApp(app) {
  const document = app.ownerDocument;
  const active = document?.activeElement;
  const activeId = app.contains?.(active) ? active.id : '';
  const selection = activeId && typeof active.selectionStart === 'number'
    ? [active.selectionStart, active.selectionEnd, active.selectionDirection] : null;
  const focus = state.focusTarget ? { id: state.focusTarget, selection: null }
    : activeId ? { id: activeId, selection } : suspendedFocus;
  suspendedFocus = null;
  const oldShell = app.querySelector('.shell');
  if (oldShell) state.scrollPositions[oldShell.dataset.pageKey] = oldShell.scrollTop;
  const oldDialog = app.querySelector('dialog');
  const dialogScroll = oldDialog?.scrollTop || 0;
  const pageKey = state.route === 'settings' ? `settings-${state.settingsSection}` : state.route;

  app.innerHTML = `<div class="app-window">
    ${renderTitlebar()}
    <div class="app-body">${state.settings ? renderNavigation() : ''}
      <main class="shell" id="main-content" data-page-key="${pageKey}">
        ${state.settings ? renderPage() : renderLoading()}
      </main>
    </div>
  </div><div class="toast-stack" id="toast-stack" aria-live="polite" aria-relevant="additions"></div>
  ${renderDialog()}`;

  const shell = app.querySelector('.shell');
  if (shell) shell.scrollTop = state.scrollPositions[pageKey] || 0;
  refreshToasts(app);
  const dialog = app.querySelector('dialog');
  if (dialog && !dialog.open) dialog.showModal();
  if (dialog && oldDialog?.className === dialog.className) dialog.scrollTop = dialogScroll;
  let target = document?.getElementById(focus?.id);
  if (dialog && !dialog.contains(target)) target = dialog.querySelector('[data-dialog-focus]');
  if (target?.matches(':disabled')) {
    suspendedFocus = focus;
  } else if (target?.getClientRects().length) {
    target.focus({ preventScroll: true });
    if (target.id === focus?.id && focus.selection) target.setSelectionRange(...focus.selection);
  } else if (focus && !dialog) {
    document?.getElementById('page-title')?.focus({ preventScroll: true });
  }
  state.focusTarget = '';
}

function renderTitlebar() {
  return `<header class="titlebar">
    <div class="brand-mark" aria-hidden="true">${icon('cast')}</div><span class="titlebar-title">MirrorMe</span>
    <div class="window-controls">
      <button class="caption-button" id="window-minimise" data-waction="minimise" aria-label="Minimize" title="Minimize">${icon('minus')}</button>
      <button class="caption-button" id="window-maximise" data-waction="maximise" aria-label="${state.maximised ? 'Restore' : 'Maximize'}" title="${state.maximised ? 'Restore' : 'Maximize'}">${icon(state.maximised ? 'copy' : 'square')}</button>
      <button class="caption-button caption-close" id="window-hide" data-waction="hide" aria-label="Close to system tray" title="Close to tray (keeps receiving)">${icon('close')}</button>
    </div>
  </header>`;
}

function renderNavigation() {
  const item = (route, name, glyph, shortcut = '') => `<button type="button" id="nav-${route}"
    class="nav-item${state.route === route ? ' is-active' : ''}" data-action="nav-${route}"
    ${state.route === route ? 'aria-current="page"' : ''} title="${name}${shortcut ? ` (${shortcut})` : ''}">
    ${icon(glyph)}<span>${name}</span>${route === 'settings' ? `<span class="draft-dot" data-draft-dot ${hasDraftChanges() ? '' : 'hidden'} aria-label="Unsaved changes"></span>` : ''}</button>`;
  return `<aside class="sidebar"><nav aria-label="Main navigation">
    ${item('home', 'Mirror', 'cast')}${item('settings', 'Settings', 'settings', 'Ctrl+,')}
    <div class="nav-spacer"></div>${item('about', 'Help & about', 'help')}
  </nav><div class="receiver-indicator" role="status">
    <span class="status-dot" data-receiver-tone="${statusMeta(state.status.status).tone}" aria-hidden="true"></span>
    <span data-receiver-label>${receiverLabel()}</span>
  </div></aside>`;
}

function renderLoading() {
  return `<div class="empty-screen">${icon(state.loading ? 'loader' : 'alert', state.loading ? 'spin' : '')}
    <h1>${state.loading ? 'Opening MirrorMe' : "MirrorMe couldn't open"}</h1>
    ${state.error ? `<p role="alert">${escHtml(state.error)}</p>` : '<p>Getting things ready.</p>'}
    ${state.loading ? '' : button('reload', 'Try again', { primary: true })}</div>`;
}

function renderPage() {
  if (state.route === 'settings') return renderSettings();
  if (state.route === 'about') return renderAbout();
  if (state.settings.firstRun) return renderOnboarding();
  return renderHome();
}

function deviceScene() {
  return `<div class="device-scene" data-scene="${state.status.status}" aria-hidden="true">
    <div class="scene-desktop"><div class="desktop-display">
      <span class="desktop-window-title">iPhone screen</span>
      ${icon(state.status.status === 'mirroring' ? 'monitor-play' : 'cast', 'desktop-symbol')}
      <span class="desktop-taskbar"></span></div><div class="desktop-stand"></div></div>
    <div class="scene-phone"><span class="phone-speaker"></span>${icon('cast', 'phone-symbol')}<span class="phone-home"></span></div>
    <span class="scene-wireless">${icon('wifi')}</span>
    <span class="scene-caption">Separate video window</span>
  </div>`;
}

function receiverName(id) {
  return `<div class="receiver-name"><span class="receiver-name-icon">${icon('monitor')}</span>
    <div><span class="field-caption">This PC</span><strong title="${escAttr(state.settings.deviceName)}">${escHtml(state.settings.deviceName)}</strong></div>
    ${button('copy-device-name', '<span class="sr-only">Copy PC name</span>', {
      id, quiet: true, small: true, icon: 'copy', attrs: 'title="Copy PC name"',
    })}</div>`;
}

function pinPanel() {
  if (!state.settings.requirePin || !state.settings.pinCode) return '';
  return `<div class="pairing-code"><div>${icon('shield')}<span>Pairing code<span class="field-caption">Enter on your iPhone if asked.</span></span></div>
    <output aria-label="Pairing code" class="pin-code">${escHtml(state.settings.pinCode)}</output></div>`;
}

function renderHome() {
  const snapshot = state.status;
  const slow = snapshot.status === 'connecting' && state.connectionSlow;
  const title = connectionTitle(snapshot, slow);
  return `<div class="page home-page">${heading('Mirror')}${errorNotice()}
    <section class="mirror-stage" aria-labelledby="connection-title">
      <div class="stage-main">
        <div class="connection-copy">
          <div class="connection-heading" role="status">
            <h2 id="connection-title">${title}</h2><p>${connectionDescription(snapshot, slow)}</p>
          </div>
          ${receiverName('copy-home-name')}
          ${snapshot.status === 'connecting' ? connectionProgress(slow) : ''}
          ${snapshot.status === 'mirroring' ? `<div class="session-time">${icon('check')}<span>Connected <span data-elapsed>${escHtml(formatElapsedSince(snapshot.connectedAt))}</span></span></div>` : ''}
          ${snapshot.status === 'error' && snapshot.lastError ? `<p class="receiver-error" role="alert">${escHtml(snapshot.lastError)}</p>` : ''}
          <div class="connection-actions">${homeActions(snapshot.status, slow)}</div>
        </div>
        ${deviceScene()}
      </div>
      ${pinPanel()}
      <div class="stage-footer"><span class="network-note">${icon('wifi')}Same network. No cables.</span>
        ${button('picture-settings', `${shortResolution()} &middot; Audio ${state.settings.audioEnabled ? 'on' : 'off'}`, {
          quiet: true, small: true, icon: state.settings.audioEnabled ? 'volume' : 'muted',
          attrs: 'title="Picture and sound settings"',
        })}</div>
    </section>
  </div>`;
}

function connectionDescription(snapshot, slow) {
  switch (snapshot.status) {
    case 'stopped': return "Make this PC available, then connect from your iPhone's Screen Mirroring menu.";
    case 'starting': return snapshot.setupKind === 'runtime'
      ? snapshot.setupProgress >= 100 ? 'Download complete. Checking the receiver and its video decoder before installing.'
        : `Downloading receiver files from GitHub: ${Math.max(0, Math.min(100, Number(snapshot.setupProgress) || 0))}%. You can cancel at any time.`
      : 'Starting the receiver and making this PC discoverable on your network.';
    case 'needs-setup': return snapshot.setupKind === 'runtime'
      ? 'Download 113 MB of receiver files once from the UxPlay Windows project on GitHub. MirrorMe checks the download before installing it. No separate desktop app is opened.'
      : 'Allow Bonjour, the discovery service that helps your iPhone find this PC. Windows may ask for administrator permission.';
    case 'advertising': return 'On your iPhone, open <strong>Control Center</strong>, tap <strong>Screen Mirroring</strong>, then choose this PC.';
    case 'connecting': return snapshot.videoReceived
      ? slow ? 'Video has arrived, but Windows has not displayed it. Try software decoding in Picture & sound, then reconnect.'
        : 'Video has arrived. Opening your mirrored screen in its own window.'
      : slow
      ? `${escHtml(snapshot.deviceName || 'Your iPhone')} was found, but video hasn't arrived. Stop Screen Mirroring on your iPhone, then try again.`
      : `${escHtml(snapshot.deviceName || 'Your iPhone')} was found. Waiting for its screen to arrive.`;
    case 'mirroring': return `${escHtml(snapshot.deviceName || 'Your iPhone')} is sharing its screen in <strong>MirrorMe - iPhone screen</strong>. Bring that window forward whenever you need it.`;
    case 'paused': return "The receiver paused the video. Unlock your iPhone to resume. If it doesn't resume, stop <strong>Screen Mirroring</strong> on your iPhone, then choose this PC again.";
    case 'error': return 'The receiver could not stay ready. Try again, or check the connection guide for help.';
    default: return 'The receiver has not reported a usable state. Try starting it again.';
  }
}

function connectionTitle(snapshot, slow) {
  if (snapshot.setupKind === 'runtime') {
    if (snapshot.status === 'needs-setup') return 'One download before you connect';
    if (snapshot.status === 'starting') return 'Getting mirroring ready';
  }
  if (snapshot.status === 'connecting') {
    if (snapshot.videoReceived) return slow ? 'Your video is waiting to open' : 'Opening your mirrored screen';
    if (slow) return "Waiting for your iPhone's video";
  }
  return statusMeta(snapshot.status).title;
}

function receiverLabel() {
  if (state.status.status === 'connecting') {
    if (state.status.videoReceived) return 'Opening screen';
    if (state.connectionSlow) return 'Waiting for video';
  }
  return statusMeta(state.status.status).label;
}

function connectionProgress(slow) {
  return `<ol class="connection-progress" aria-label="Connection progress">
    <li>${icon('check')}Phone found</li>
    <li class="${slow ? 'is-waiting' : ''}">${icon(slow ? 'info' : 'loader', slow ? '' : 'spin')}${state.status.videoReceived ? 'Opening screen' : 'Waiting for video'}</li>
  </ol>`;
}

function homeActions(status, slow) {
  const blocked = state.busy || state.saving;
  const cancel = button('stop-mirroring', 'Cancel', { disabled: state.busyAction === 'stop' });
  if (status === 'starting') return cancel;
  if (status === 'connecting') return `${slow ? button('start-mirroring', 'Try again', { primary: true, icon: 'refresh', disabled: blocked }) : ''}${cancel}
    ${slow && state.status.videoReceived ? button('picture-settings', 'Picture & sound', { quiet: true, id: 'video-recovery-settings' }) : ''}
    ${slow ? button('open-guide', 'Connection help', { quiet: true, id: 'home-guide' }) : ''}`;
  if (status === 'needs-setup') return `${button('confirm-setup', state.status.setupKind === 'runtime' ? 'Download receiver files' : 'Allow discovery', { primary: true, icon: 'shield', disabled: blocked })}${cancel}`;
  if (status === 'advertising') return `${button('open-guide', 'How to connect', { primary: true, id: 'home-guide', icon: 'phone' })}
    ${button('stop-mirroring', 'Stop receiving', { quiet: true, disabled: blocked })}`;
  if (status === 'mirroring') return `${button('show-mirrored-screen', 'Show screen', { primary: true, icon: 'expand' })}
    ${button('stop-mirroring', 'Stop mirroring', { quiet: true, disabled: blocked })}`;
  if (status === 'paused') return `${button('stop-mirroring', 'Stop mirroring', { disabled: state.busyAction === 'stop' })}
    ${button('open-guide', 'Connection help', { quiet: true, id: 'home-guide' })}`;
  return `${button('start-mirroring', status === 'stopped' ? 'Start receiving' : 'Try again', {
    primary: true, icon: status === 'stopped' ? 'play' : 'refresh', disabled: blocked,
  })}${button('open-guide', 'Connection guide', { quiet: true, id: 'home-guide' })}`;
}

function shortResolution() {
  return { auto: 'Automatic quality', '1280x720': '720p', '1920x1080': '1080p', '3840x2160': '4K' }[state.settings.resolution] || 'Automatic quality';
}

function connectionSteps() {
  return `<ol class="connection-steps">
    <li><span class="step-number" aria-hidden="true">1</span><div><h3>Open Control Center</h3><p>Swipe down from the top-right corner of your iPhone.</p></div></li>
    <li><span class="step-number" aria-hidden="true">2</span><div><h3>Tap Screen Mirroring <span class="screen-mirroring-symbol" aria-hidden="true"></span></h3><p>Look for the two overlapping rectangles.</p></div></li>
    <li><span class="step-number" aria-hidden="true">3</span><div><h3>Choose <span class="inline-device-name">${escHtml(state.settings.deviceName)}</span></h3><p>Your screen opens in its own window on this PC.</p></div></li>
  </ol>`;
}

function renderOnboarding() {
  const second = state.setupStep === 2;
  const ready = state.status.status === 'advertising';
  const mirrored = state.status.status === 'mirroring';
  const paused = state.status.status === 'paused';
  const connecting = state.status.status === 'connecting';
  const setupTitle = mirrored ? "You're connected" : ready ? 'Now, pick up your iPhone'
    : connectionTitle(state.status, state.connectionSlow);
  const setupDescription = mirrored ? 'Your mirrored screen is ready in its own window.'
    : ready ? 'Keep both devices on the same network, then follow these steps.'
    : connectionDescription(state.status, state.connectionSlow);
  return `<div class="page onboarding-page">
    ${heading('Welcome to MirrorMe', '', '<span class="step-caption">Step ' + state.setupStep + ' of 2</span>')}
    ${errorNotice()}
    ${second ? `<section class="onboarding-surface setup-connect">
      <div class="setup-heading"><h2>${setupTitle}</h2><p>${setupDescription}</p></div>
      <div class="setup-status" role="status">${icon(statusMeta(state.status.status).icon, state.status.status === 'starting' ? 'spin' : '')}
        <span>${ready ? 'This PC is ready to connect' : statusMeta(state.status.status).label}</span>
        ${state.status.status === 'error' && state.status.lastError ? `<p class="receiver-error" role="alert">${escHtml(state.status.lastError)}</p>` : ''}
        ${!ready && !mirrored ? `<div class="setup-status-actions">${homeActions(state.status.status, state.connectionSlow)}</div>` : ''}
      </div>
      ${mirrored ? `<div class="onboarding-success">${icon('check')}<p>${escHtml(state.status.deviceName || 'Your iPhone')} is mirroring.</p>
        ${button('show-mirrored-screen', 'Show screen', { primary: true, icon: 'expand' })}</div>` : ready ? connectionSteps()
        : connecting ? connectionProgress(state.connectionSlow)
        : paused ? '<p class="setup-next">The separate video window is hidden until video resumes.</p>'
        : `<p class="setup-next">${icon('phone')}Once this PC is ready, we'll show you how to connect your iPhone.</p>`}
      ${pinPanel()}
      <div class="onboarding-footer">
        ${button('setup-back', 'Back', { quiet: true, icon: 'arrow-left', disabled: state.busy || state.saving })}
        ${button('dismiss-first-run', state.saving ? 'Saving...' : ready || mirrored || paused ? 'Done' : 'Back to Mirror', { primary: ready, disabled: state.saving || state.busy })}
      </div>
    </section>` : `<form class="onboarding-surface" id="setup-form">
      <div class="setup-intro">
        <div><h2>Your iPhone.<br>A little more room.</h2><p>Bring your iPhone's screen and sound to Windows. No cables. No extra app on your phone.</p></div>
        ${deviceScene()}
      </div>
      <div class="setup-name-row"><div><label for="setup-name">What should your iPhone call this PC?</label>
        <p id="setup-name-hint">This name appears in Screen Mirroring.</p></div>
        <div class="setup-name-input"><input class="input" id="setup-name" value="${escAttr(state.setupName)}" maxlength="${MAX_PC_NAME_BYTES}"
          autocomplete="off" spellcheck="false" required aria-describedby="setup-name-hint name-error"
          aria-invalid="${Boolean(state.fieldError)}" ${state.saving ? 'disabled' : ''}>
          <p class="field-error" id="name-error" ${state.fieldError ? '' : 'hidden'}>${escHtml(state.fieldError)}</p></div>
      </div>
      <div class="onboarding-footer"><span class="setup-network">${icon('wifi')}One shared network is all you need.</span>
        <div class="button-row">${button('dismiss-first-run', 'Skip setup', { quiet: true, disabled: state.saving || state.busy })}
          <button type="submit" class="btn btn-primary" id="setup-continue" ${state.saving || state.busy ? 'disabled' : ''}>
            ${state.saving ? 'Saving...' : 'Continue'}${icon('arrow-right')}</button></div>
      </div>
    </form>`}
    <p class="onboarding-note">${icon('info')}Closing the window keeps MirrorMe in your system tray. Quit from the tray menu to stop it completely.</p>
  </div>`;
}

function renderSettings() {
  return `<div class="page settings-page">
    ${heading('Settings', 'Make mirroring work your way.')}${errorNotice()}
    <div class="settings-tabs" role="tablist" aria-label="Settings category">
      ${SECTIONS.map(([key, label]) => `<button type="button" role="tab" id="tab-${key}"
        aria-selected="${state.settingsSection === key}" aria-controls="panel-${key}"
        tabindex="${state.settingsSection === key ? '0' : '-1'}" data-action="settings-section" data-section="${key}">${label}</button>`).join('')}
    </div>
    ${SECTIONS.map(([key, label]) => `<section id="panel-${key}" role="tabpanel" aria-labelledby="tab-${key}"
      class="settings-panel" ${state.settingsSection === key ? '' : 'hidden'}>
      <fieldset ${state.saving ? 'disabled' : ''}><legend class="sr-only">${label}</legend>
        ${{ connection: connectionSettings, picture: pictureSettings, app: appSettings }[key]()}
      </fieldset>
    </section>`).join('')}
    <div class="save-bar" data-save-bar ${hasDraftChanges() || state.saving ? '' : 'hidden'} aria-label="Unsaved settings">
      <div><strong data-save-status>${state.saving ? 'Saving changes...' : 'Unsaved changes'}</strong><p>Connection changes restart the receiver.</p></div>
      <div class="button-row">${button('revert-settings', 'Revert', { disabled: state.saving })}
        ${button('save-settings', state.saving ? 'Saving...' : 'Save changes', { primary: true, disabled: state.saving, attrs: 'title="Save changes (Ctrl+S)"' })}</div>
    </div>
  </div>`;
}

function settingsGroup(title, rows) {
  return `<section class="settings-group"><h2>${title}</h2><div class="settings-rows">${rows}</div></section>`;
}

function textRow(field, label, description, value) {
  return `<div class="setting-row"><div class="setting-copy"><label for="field-${field}">${label}</label>
    <p id="hint-${field}">${description}</p></div><div class="setting-control">
    <input class="input" type="text" id="field-${field}" data-field="${field}" value="${escAttr(value)}"
      maxlength="${MAX_PC_NAME_BYTES}" spellcheck="false" autocomplete="off" aria-describedby="hint-${field} name-error"
      aria-invalid="${Boolean(state.fieldError)}">
    <p id="name-error" class="field-error" ${state.fieldError ? '' : 'hidden'}>${escHtml(state.fieldError)}</p></div></div>`;
}

function toggleRow(field, label, description, checked) {
  return `<label class="setting-row" for="field-${field}"><span class="setting-copy"><span class="setting-label" id="label-${field}">${label}</span>
    <span id="hint-${field}" class="setting-description">${description}</span></span>
    <span class="switch"><input type="checkbox" role="switch" id="field-${field}" data-field="${field}"
      aria-labelledby="label-${field}" aria-describedby="hint-${field}" ${checked ? 'checked' : ''}><span class="switch-track" aria-hidden="true"></span></span></label>`;
}

function selectRow(field, label, description, options, value) {
  return `<div class="setting-row"><div class="setting-copy"><label for="field-${field}">${label}</label>
    <p id="hint-${field}">${description}</p></div><div class="setting-control">
    <select class="input select" id="field-${field}" data-field="${field}" aria-describedby="hint-${field}">
      ${options.map(([key, text]) => `<option value="${escAttr(key)}" ${String(value) === String(key) ? 'selected' : ''}>${escHtml(text)}</option>`).join('')}
    </select></div></div>`;
}

function connectionSettings() {
  const settings = state.draft;
  const hasPin = state.settings.requirePin && state.settings.pinCode;
  return `${settingsGroup('This PC', textRow('deviceName', 'PC name', "The name in your iPhone's Screen Mirroring list.", settings.deviceName))}
    ${settingsGroup('Pairing', toggleRow('requirePin', 'Require a pairing code', 'Ask for a four-digit code when a device pairs.', settings.requirePin)
      + (settings.requirePin ? `<div class="setting-row pin-setting"><div class="setting-copy"><span class="setting-label">Pairing code</span>
        <p>${hasPin ? 'Enter this code on your iPhone when asked.' : 'A code will be created when you save.'}</p></div>
        <div class="pin-setting-control">${hasPin ? `<output class="pin-code" aria-label="Current pairing code">${escHtml(state.settings.pinCode)}</output>` : ''}
          ${button('regenerate-pin', 'New code', { small: true, disabled: state.saving || !hasPin, icon: 'refresh' })}</div></div>` : ''))}
    ${disclosure('advanced-connection', 'Advanced connection settings',
      toggleRow('preferNewestConnection', 'Let another iPhone take over', 'A new connection replaces the current session.', settings.preferNewestConnection)
      + selectRow('idleTimeoutSeconds', 'Disconnect an inactive session', 'Release the connection when the receiver stops hearing from it.', IDLE, settings.idleTimeoutSeconds), 'settings-disclosure')}`;
}

function pictureSettings() {
  const settings = state.draft;
  return `${settingsGroup('Picture', selectRow('resolution', 'Maximum resolution', 'Automatic is a good place to start.', RESOLUTIONS.map(value => [value, resolutionLabel(value)]), settings.resolution)
    + selectRow('maxFps', 'Maximum frame rate', 'Higher limits need more network bandwidth.', FPS, settings.maxFps))}
    ${settingsGroup('Sound', toggleRow('audioEnabled', 'Play iPhone audio', "Use this PC's speakers for mirrored sound.", settings.audioEnabled))}
    ${disclosure('advanced-picture', 'Advanced picture settings',
      (state.status.backend === 'native'
        ? '<div class="setting-row"><div class="setting-copy"><strong>Windows video decoder</strong><p>This preview uses software decoding. Hardware decoding is not enabled.</p></div></div>'
        : toggleRow('hardwareDecode', 'Use hardware acceleration', 'Let your graphics processor handle video decoding.', settings.hardwareDecode))
      + toggleRow('h265', 'Allow HEVC video', 'Enable the H.265 codec for compatible devices.', settings.h265), 'settings-disclosure')}
    <p class="settings-note">These are quality limits, not a measurement of the live stream. Your iPhone and network determine the final picture.</p>`;
}

function appSettings() {
  const settings = state.draft;
  return `${settingsGroup('Appearance', selectRow('theme', 'Theme', 'Preview a look, then save to keep it.', THEMES, settings.theme)
    + toggleRow('alwaysOnTop', 'Keep MirrorMe on top', 'Keep this control window above other apps.', settings.alwaysOnTop))}
    ${settingsGroup('When MirrorMe opens',
      toggleRow('autoStartMirroring', 'Start receiving automatically', 'Be ready for your iPhone as soon as the app opens.', settings.autoStartMirroring)
      + toggleRow('startMinimized', 'Open in the system tray', 'Keep the control window out of the way.', settings.startMinimized))}
    ${disclosure('windows-startup', 'Windows startup',
      toggleRow('launchAtStartup', 'Launch when I sign in', 'Start MirrorMe in the tray when you sign in to Windows.', settings.launchAtStartup), 'settings-disclosure')}
    ${settingsGroup('Troubleshooting', toggleRow('verboseLogging', 'Verbose logging',
      'Save receiver events and quality settings to local files. No screen content, pairing codes or packet data.', settings.verboseLogging))}
    <p data-log-warning role="alert" class="field-error" ${state.logWarning ? '' : 'hidden'}>${escHtml(state.logWarning)}</p>
    <p class="settings-note">Two log files, up to 1 MB each. Turning logging off keeps existing files.</p>
    <p class="settings-path">${escHtml(state.logsFolder)}</p>
    <div class="button-row">${button('open-logs-folder', 'Open logs folder', { quiet: true, small: true })}
      ${button('copy-logs-path', 'Copy logs path', { quiet: true, small: true, icon: 'copy' })}</div>
    ${connectionDetails('settings-details')}`;
}

function connectionDetails(key) {
  return disclosure(key, 'Connection details', `<dl class="diagnostics">
    <div><dt>Receiver</dt><dd data-diagnostic-status>${escHtml(statusMeta(state.status.status).label)}</dd></div>
    ${state.status.backend === 'native' ? '<div><dt>Implementation</dt><dd>Built into MirrorMe</dd></div>' : ''}
    <div><dt>Version</dt><dd>${escHtml(state.version || 'Development')}</dd></div>
    <div><dt>Device</dt><dd data-diagnostic-device>${escHtml(deviceLabel(state.status))}</dd></div>
  </dl>
  ${button('copy-diagnostics', 'Copy details', { id: `copy-${key}`, quiet: true, small: true, icon: 'copy' })}`, 'connection-details');
}

function helpAnswers() {
  return `${disclosure('help-discovery', "My PC isn't in Screen Mirroring", `<p>Keep your iPhone and PC on the same trusted network. A guest network or VPN may prevent them from finding each other.</p>
    <p>Make sure MirrorMe says <strong>Ready to connect</strong>. If Windows asks about network access, allow the MirrorMe receiver on your private network. Do not turn off your firewall.</p>`)}
    ${disclosure('help-connecting', 'My iPhone is stuck on Connecting', `<p>Finding your iPhone and receiving its video are separate steps. MirrorMe only marks the session as mirroring after the receiver reports video.</p>
      <p>On your iPhone, stop Screen Mirroring. Choose <strong>Try again</strong> in MirrorMe, then select this PC again on your iPhone. Connection details and logging are in <strong>Settings &gt; App &gt; Troubleshooting</strong>.</p>`)}
    ${disclosure('help-paused', 'Mirroring is paused', `<p>Paused means the receiver reported a pause, not that MirrorMe detected a locked phone from missing video.</p>
      <p>Unlock your iPhone to resume. If video doesn't resume, stop <strong>Screen Mirroring</strong> on your iPhone, then choose this PC again. The video window stays hidden while paused; you can still stop mirroring in MirrorMe.</p>`)}
    ${disclosure('help-video', 'The picture is black or sound is missing', `<p>Some apps block screen mirroring of protected video. Try the iPhone Home Screen or a photo first.</p>
      <p>For sound, enable <strong>Play iPhone audio</strong> in Picture &amp; sound, and check your PC's volume and audio output. For an unstable picture, try 720p at 30 fps.</p>`)}
    ${disclosure('help-tray', 'What happens when I close the window?', `<p>MirrorMe keeps receiving in the system tray, near the Windows clock. Use its tray menu to show the app, stop receiving, or quit completely.</p>
      <p>One app, one tray icon. The receiver has no separate control app; only the mirrored video gets its own window.</p>`)}`;
}

function renderAbout() {
  const native = state.status.backend === 'native';
  const receiverCredits = native
    ? [['AirPlay protocol', 'https://github.com/leapbtw/libuxplay'], ['FFmpeg', 'https://ffmpeg.org'],
      ['OpenSSL', 'https://openssl.org'], ['libplist', 'https://github.com/libimobiledevice/libplist']]
    : [['UxPlay', 'https://github.com/FDH2/UxPlay'], ['libuxplay', 'https://github.com/leapbtw/libuxplay'],
      ['GStreamer', 'https://gstreamer.freedesktop.org/']];
  return `<div class="page help-page">${heading('Help &amp; about')}${errorNotice()}
    <section class="help-intro"><div class="about-mark" aria-hidden="true">${icon('cast')}</div>
      <div><h2>MirrorMe</h2><p>iPhone screen mirroring, made for Windows.</p><span class="version-label">Version ${escHtml(state.version || 'Development')}</span></div>
      ${button('open-guide', 'Connection guide', { id: 'about-guide', primary: true, icon: 'phone' })}</section>
    <section class="help-section"><h2>A little help</h2>${helpAnswers()}</section>
    ${disclosure('shortcuts', 'Keyboard shortcuts', `<dl class="shortcuts">
      <div><dt>Open Settings</dt><dd><kbd>Ctrl</kbd> <kbd>,</kbd></dd></div>
      <div><dt>Save changes</dt><dd><kbd>Ctrl</kbd> <kbd>S</kbd></dd></div>
      <div><dt>Connection guide</dt><dd><kbd>F1</kbd></dd></div>
      <div><dt>Close a dialog</dt><dd><kbd>Esc</kbd></dd></div></dl>`)}
    ${disclosure('support-files', 'Settings &amp; support files', `<p>Your preferences are stored on this PC.</p>
      <p class="settings-path">${escHtml(state.settingsFolder)}</p><div class="button-row">
      ${button('open-settings-folder', 'Open folder', { small: true })}${button('copy-settings-folder', 'Copy path', { quiet: true, small: true, icon: 'copy' })}</div>`)}
    ${disclosure('credits', 'Built with open source', `<p>${native
      ? 'AirPlay protocol code and audio codecs are built into MirrorMe. Windows handles video decoding and audio output. No separate receiver download or discovery service is installed.'
      : 'MirrorMe uses UxPlay to receive AirPlay streams, GStreamer for picture and sound, and Wails for its Windows interface. The receiver runs in the background and stops when you quit.'}</p>
      <div class="credit-links">${[
        ...receiverCredits, ['Wails', 'https://wails.io'],
        ['Postrboard', 'https://github.com/burkeholland/postrboard-design'], ['Lucide', 'https://lucide.dev'],
      ].map(([label, url]) => `<a href="${url}" id="credit-${label.toLowerCase().replaceAll(' ', '-')}" data-action="open-link" data-url="${url}">${label}${icon('arrow-up-right')}</a>`).join('')}</div>
      <p class="settings-note">License information is included with the application. MirrorMe is not affiliated with Apple.</p>`)}
    <footer class="about-footer"><p>Quit stops the receiver and closes MirrorMe.</p>${button('quit', 'Quit MirrorMe')}</footer>
  </div>`;
}

function renderDialog() {
  if (!state.dialog) return '';
  if (state.dialog.kind === 'unsaved') return `<dialog class="content-dialog unsaved-dialog" aria-labelledby="dialog-title" aria-describedby="dialog-description">
    <div class="dialog-body"><h2 id="dialog-title">Save your changes?</h2>
      <p id="dialog-description">Keep your new settings, or discard them before leaving this page.</p>
      ${errorNotice()}${state.fieldError ? `<p class="field-error" role="alert">${escHtml(state.fieldError)}</p>` : ''}</div>
    <div class="dialog-footer">${button('close-dialog', 'Keep editing', { id: 'dialog-cancel', disabled: state.saving, attrs: 'data-dialog-focus' })}
      ${button('discard-and-leave', 'Discard', { disabled: state.saving })}
      ${button('save-and-leave', state.saving ? 'Saving...' : 'Save changes', { primary: true, disabled: state.saving })}</div></dialog>`;
  return `<dialog class="content-dialog guide-dialog" aria-labelledby="dialog-title">
    <header class="dialog-header"><div><h2 id="dialog-title">Connect your iPhone</h2><p>Your next step is on your phone.</p></div>
      ${button('close-dialog', '<span class="sr-only">Close connection guide</span>', {
        id: 'dialog-close', quiet: true, small: true, icon: 'close', attrs: 'data-dialog-focus',
      })}</header>
    <div class="dialog-body">${errorNotice()}${receiverName('guide-copy-name')}
      ${state.status.status === 'paused' ? `<h3>Mirroring is paused</h3><p>${connectionDescription(state.status, false)}</p>` : connectionSteps()}${pinPanel()}
      <div class="guide-notes"><p>${icon('wifi')}Keep both devices on the same network.</p>
        <p>${icon('info')}On an iPhone with a Home button, swipe up from the bottom to open Control Center.</p></div>
      ${disclosure('guide-trouble', 'Still not connecting?', `<p>Check that MirrorMe is ready to connect. If your phone is stuck, stop Screen Mirroring on the phone, restart receiving in MirrorMe, then choose this PC again.</p>
        <p>Guest networks and VPNs can block discovery. Use a trusted local network and allow the receiver through Windows Firewall on private networks. Leave the firewall enabled.</p>`)}
    </div>
    <div class="dialog-footer"><span>To end a session, tap Stop Mirroring on your iPhone.</span>
      ${button('close-dialog', 'Got it', { id: 'guide-done', primary: true })}</div></dialog>`;
}

export function refreshToasts(app) {
  const stack = app.querySelector('#toast-stack');
  if (stack) stack.innerHTML = state.toasts.map(toast => `<div class="toast" data-tone="${toast.tone}">
    ${icon(toast.tone === 'success' ? 'check' : toast.tone === 'danger' ? 'alert' : 'info')}
    <span>${escHtml(toast.message)}</span><button type="button" class="toast-close" data-action="dismiss-toast"
      id="toast-close-${toast.id}" data-toast-id="${toast.id}" aria-label="Dismiss notification">${icon('close')}</button></div>`).join('');
}

export function refreshSaveBar(app) {
  const changed = hasDraftChanges();
  const bar = app.querySelector('[data-save-bar]');
  if (bar) bar.hidden = !changed && !state.saving;
  for (const action of ['save-settings', 'revert-settings']) {
    const control = app.querySelector(`[data-action="${action}"]`);
    if (control) control.disabled = !changed || state.saving;
  }
  const copy = app.querySelector('[data-save-status]');
  if (copy) copy.textContent = state.saving ? 'Saving changes...' : 'Unsaved changes';
  const dot = app.querySelector('[data-draft-dot]');
  if (dot) dot.hidden = !changed;
  const error = app.querySelector('#name-error');
  if (error) { error.textContent = state.fieldError; error.hidden = !state.fieldError; }
  const name = app.querySelector('#field-deviceName, #setup-name');
  if (name) name.setAttribute('aria-invalid', String(Boolean(state.fieldError)));
  if (!state.error) app.querySelector('[data-app-error]')?.remove();
}

export function refreshReceiverStatus(app) {
  const meta = statusMeta(state.status.status);
  const label = app.querySelector('[data-receiver-label]');
  if (label) label.textContent = receiverLabel();
  const dot = app.querySelector('[data-receiver-tone]');
  if (dot) dot.dataset.receiverTone = meta.tone;
  const status = app.querySelector('[data-diagnostic-status]');
  if (status) status.textContent = meta.label;
  const device = app.querySelector('[data-diagnostic-device]');
  if (device) device.textContent = deviceLabel(state.status);
  const warning = app.querySelector('[data-log-warning]');
  if (warning) {
    warning.textContent = state.logWarning;
    warning.hidden = !state.logWarning;
  }
}

export function refreshWindowControls(app) {
  const control = app.querySelector('[data-waction="maximise"]');
  if (!control) return;
  control.innerHTML = icon(state.maximised ? 'copy' : 'square');
  control.setAttribute('aria-label', state.maximised ? 'Restore' : 'Maximize');
  control.title = state.maximised ? 'Restore' : 'Maximize';
}

export function refreshElapsed(app) {
  const elapsed = app.querySelector('[data-elapsed]');
  if (elapsed) elapsed.textContent = formatElapsedSince(state.status.connectedAt);
}
