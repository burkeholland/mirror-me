export const settingsFixture = {
  deviceName: 'Preview PC',
  resolution: 'auto',
  maxFps: 0,
  audioEnabled: true,
  hardwareDecode: true,
  h265: false,
  preferNewestConnection: true,
  idleTimeoutSeconds: 15,
  requirePin: false,
  pinCode: '',
  launchAtStartup: false,
  startMinimized: false,
  autoStartMirroring: true,
  alwaysOnTop: false,
  theme: 'system',
  firstRun: false,
};

export function snapshotFixture(status) {
  const connected = status === 'connecting' || status === 'mirroring';
  return {
    status,
    deviceName: connected ? 'Preview iPhone' : '',
    deviceModel: connected ? 'Preview device' : '',
    connectedAt: status === 'mirroring' ? new Date(Date.now() - 67000).toISOString() : null,
    lastError: status === 'error' ? 'Preview: the receiver did not become ready. Try starting it again.' : '',
  };
}
