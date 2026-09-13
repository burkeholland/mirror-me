export const DEFAULT_NOTE = 'Make something worth showing.\n\nSketch the idea.\nShare the small details.\nSee the bigger picture.';

export function initialState(reducedMotion = false) {
  return { phase: 'mirroring', content: 'photos', landscape: false, motion: !reducedMotion, seconds: 0, note: DEFAULT_NOTE, videoMinimised: false };
}

export function reduce(state, event) {
  switch (event.type) {
    case 'status':
      if (!['mirroring', 'advertising', 'stopped'].includes(event.value)) throw new RangeError('Unknown receiver state');
      return { ...state, phase: event.value, videoMinimised: false };
    case 'content':
      if (!['photos', 'notes', 'clock'].includes(event.value)) throw new RangeError('Unknown sample content');
      return { ...state, content: event.value };
    case 'rotate': return { ...state, landscape: !state.landscape };
    case 'motion': return { ...state, motion: Boolean(event.value) };
    case 'tick': return state.motion ? { ...state, seconds: (state.seconds + 1) % 3600 } : state;
    case 'note': return { ...state, note: Array.from(String(event.value)).slice(0, 280).join('') };
    case 'minimise-video': return { ...state, videoMinimised: true };
    case 'show-video': return { ...state, videoMinimised: false };
    default: throw new RangeError(`Unknown preview action: ${event.type}`);
  }
}

export function formatTime(seconds) {
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}
