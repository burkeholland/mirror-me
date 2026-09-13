export const DEFAULT_NOTE = 'Make something worth showing.\n\nSketch the idea.\nShare the small details.\nSee the bigger picture.';

export function initialState(reducedMotion = false) {
  return { phase: 'idle', content: 'photos', landscape: false, playing: !reducedMotion, seconds: 0, note: DEFAULT_NOTE };
}

export function reduce(state, event) {
  switch (event.type) {
    case 'start': return { ...state, phase: 'connecting' };
    case 'connected': return state.phase === 'connecting' ? { ...state, phase: 'mirroring' } : state;
    case 'stop': return { ...state, phase: 'idle' };
    case 'content':
      if (!['photos', 'notes', 'clock'].includes(event.value)) throw new RangeError('Unknown sample content');
      return { ...state, content: event.value };
    case 'rotate': return { ...state, landscape: !state.landscape };
    case 'motion': return { ...state, playing: !state.playing };
    case 'pause': return { ...state, playing: false };
    case 'tick': return state.playing ? { ...state, seconds: (state.seconds + 1) % 3600 } : state;
    case 'note': return { ...state, note: Array.from(String(event.value)).slice(0, 280).join('') };
    default: throw new RangeError(`Unknown demo action: ${event.type}`);
  }
}

export function formatTime(seconds) {
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}
