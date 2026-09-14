export function exampleSettings(theme = 'light') {
  return {
    deviceName: 'Studio PC', resolution: 'auto', maxFps: 0, audioEnabled: true,
    hardwareDecode: true, h265: false, preferNewestConnection: true,
    idleTimeoutSeconds: 15, requirePin: false, pinCode: '', launchAtStartup: false,
    startMinimized: false, autoStartMirroring: true, alwaysOnTop: false,
    theme, firstRun: false, verboseLogging: false,
  };
}

// Only the native boundary is simulated. Rendering, events, dialogs, drafts,
// accessibility, and styles all come from the desktop application's entry point.
export function createPreviewBridge({ notify = () => {}, now = Date.now, theme = 'light' } = {}) {
  let settings = exampleSettings(theme);
  let maximised = false;
  const listeners = new Map();
  const snapshotFor = status => ({
    status,
    deviceName: status === 'mirroring' ? 'Example iPhone' : '',
    deviceModel: status === 'mirroring' ? 'Example device' : '',
    connectedAt: status === 'mirroring' ? new Date(now()).toISOString() : null,
    videoReceived: status === 'mirroring', lastError: '',
  });
  let snapshot = snapshotFor('mirroring');
  const emit = (name, value) => {
    for (const listener of listeners.get(name) || []) listener(structuredClone(value));
  };
  const publishStatus = status => {
    snapshot = snapshotFor(status);
    emit('engine-status', { Snapshot: snapshot, Activity: `Example session: ${status}.` });
    notify({ type: 'status', status });
  };
  const publishSettings = () => emit('settings-updated', settings);
  const nativeOnly = action => {
    throw new Error(`${action} is available in the installed app, not this browser preview.`);
  };
  const windowAction = action => notify({ type: 'window', action });

  return {
    app: {
      GetSettings: async () => structuredClone(settings),
      GetStatus: async () => structuredClone(snapshot),
      GetVersion: async () => 'Website preview - example data',
      GetSettingsFolder: async () => 'Browser preview - no settings files are created',
      GetLogsFolder: async () => 'Browser preview - no log files are created',
      SaveSettings: async next => {
        const name = next.deviceName.trim();
        if (!name || name.length > 64) throw new Error('Use a PC name between 1 and 64 characters.');
        settings = { ...structuredClone(next), deviceName: name };
        settings.pinCode = settings.requirePin ? settings.pinCode || '2468' : '';
        publishSettings();
        return structuredClone(settings);
      },
      RegeneratePinCode: async () => {
        if (!settings.requirePin) throw new Error('Save the pairing-code setting first.');
        settings.pinCode = settings.pinCode === '2468' ? '1357' : '2468';
        publishSettings();
        return structuredClone(settings);
      },
      StartMirroring: async () => publishStatus('advertising'),
      StopMirroring: async () => publishStatus('stopped'),
      ConfirmSetupAndStart: async () => nativeOnly('Installing receiver files'),
      ShowMirroredScreen: async () => {
        if (snapshot.status !== 'mirroring') return false;
        windowAction('show-video');
        return true;
      },
      ShowWindow: async () => windowAction('show-app'),
      ShowSettingsPage: async () => { windowAction('show-app'); emit('navigate', 'settings'); },
      ShowAboutPage: async () => { windowAction('show-app'); emit('navigate', 'about'); },
      OpenSettingsFolder: async () => nativeOnly('Opening a Windows folder'),
      OpenLogsFolder: async () => nativeOnly('Opening a Windows logs folder'),
      OpenExternalURL: async () => nativeOnly('Opening links from the app'),
      Quit: async () => { publishStatus('stopped'); windowAction('quit'); },
    },
    runtime: {
      EventsOnMultiple(name, callback) {
        if (!listeners.has(name)) listeners.set(name, new Set());
        listeners.get(name).add(callback);
        return () => listeners.get(name)?.delete(callback);
      },
      WindowIsMaximised: async () => maximised,
      WindowToggleMaximise: () => {
        maximised = !maximised;
        windowAction(maximised ? 'maximise' : 'restore');
      },
      WindowMinimise: () => windowAction('minimise'),
      WindowHide: () => windowAction('hide'),
      WindowSetDarkTheme: () => notify({ type: 'app-theme', mode: 'dark' }),
      WindowSetLightTheme: () => notify({ type: 'app-theme', mode: 'light' }),
      WindowSetSystemDefaultTheme: () => notify({ type: 'app-theme', mode: 'system' }),
      ClipboardSetText: async () => nativeOnly('Copying to your clipboard'),
    },
    connect: () => publishStatus('mirroring'),
    closeVideo: () => publishStatus('advertising'),
    setTheme(mode) {
      if (!['light', 'dark'].includes(mode)) throw new RangeError('Unknown preview theme');
      settings.theme = mode;
      publishSettings();
    },
    reset(mode = theme) {
      settings = exampleSettings(mode);
      maximised = false;
      publishSettings();
      publishStatus('mirroring');
    },
  };
}
