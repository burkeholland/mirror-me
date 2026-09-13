// Small, dependency-free helpers shared by render.js and state.js.

export function escHtml(v) {
  return String(v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

// Attribute values need the same escaping as text content here, but this is
// kept as a separate name so call sites document *why* they're escaping.
export const escAttr = escHtml;

const STATUS_META = {
  stopped: { icon: 'monitor', tone: 'neutral', title: 'Ready when you are', label: 'Not receiving' },
  starting: { icon: 'loader', tone: 'info', title: 'Getting your PC ready', label: 'Starting', spin: true },
  'needs-setup': { icon: 'shield', tone: 'warning', title: 'One quick Windows setup', label: 'Setup needed' },
  advertising: { icon: 'wifi', tone: 'success', title: 'Ready for your iPhone', label: 'Ready to connect' },
  connecting: { icon: 'loader', tone: 'info', title: 'Your iPhone is connecting', label: 'Connecting', spin: true },
  mirroring: { icon: 'monitor-play', tone: 'success', title: "You're mirroring", label: 'Mirroring' },
  error: { icon: 'alert', tone: 'danger', title: "Let's get you connected", label: 'Needs attention' },
};

export function statusMeta(status) {
  return STATUS_META[status] ?? {
    icon: 'alert', tone: 'danger', title: 'Receiver status unavailable', label: 'Unavailable',
  };
}

export function formatElapsedSince(isoTimestamp) {
  if (!isoTimestamp) return '';
  const started = new Date(isoTimestamp).getTime();
  if (Number.isNaN(started)) return '';
  const seconds = Math.max(0, Math.floor((Date.now() - started) / 1000));
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m`;
  if (m > 0) return `${m}m ${String(s).padStart(2, '0')}s`;
  return `${s}s`;
}

export function formatClock(date) {
  return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit', second: '2-digit' });
}

const RESOLUTION_LABELS = {
  auto: 'Automatic (recommended)',
  '1280x720': '720p (1280 × 720)',
  '1920x1080': '1080p (1920 × 1080)',
  '3840x2160': '4K (3840 × 2160)',
};

export function resolutionLabel(value) {
  return RESOLUTION_LABELS[value] ?? value;
}

export function friendlyErrorMessage(err) {
  return err?.message ?? String(err);
}
