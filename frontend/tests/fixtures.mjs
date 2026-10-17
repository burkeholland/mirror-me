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
  verboseLogging: false,
  theme: 'system',
  firstRun: false,
};

export function snapshotFixture(status) {
  const connected = ['connecting', 'mirroring', 'paused'].includes(status);
  return {
    status,
    backend: 'native',
    deviceName: connected ? 'Preview iPhone' : '',
    deviceModel: connected ? 'Preview device' : '',
    connectedAt: status === 'mirroring' ? new Date(Date.now() - 67000).toISOString() : null,
    lastError: status === 'error' ? 'Preview: the receiver did not become ready. Try starting it again.' : '',
  };
}

export const castTargetsFixture = [
  { id: 'AABBCCDDEEFF', name: 'Living Room TV', model: 'AppleTV11,1', address: '192.168.1.40', port: 7000, canMirror: true, reason: '' },
  { id: '112233445566', name: 'Kitchen speaker', model: 'AudioAccessory5,1', address: '192.168.1.41', port: 7000, canMirror: false, reason: 'Audio-only device' },
];

export function castSnapshotFixture(status = 'stopped', revision = 0) {
  return { revision, status, available: true, targets: structuredClone(castTargetsFixture),
    ...(['connecting', 'pairing', 'streaming', 'stopping'].includes(status) ? { target: { ...castTargetsFixture[0] } } : {}) };
}
