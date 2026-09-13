export function initialState(reducedMotion = false) {
  return { phase: 'mirroring', landscape: false, motion: !reducedMotion, videoMinimised: false };
}

export function reduce(state, event) {
  switch (event.type) {
    case 'status':
      if (!['mirroring', 'advertising', 'stopped'].includes(event.value)) throw new RangeError('Unknown receiver state');
      return { ...state, phase: event.value, videoMinimised: false };
    case 'rotate': return { ...state, landscape: !state.landscape };
    case 'motion': return { ...state, motion: Boolean(event.value) };
    case 'minimise-video': return { ...state, videoMinimised: true };
    case 'show-video': return { ...state, videoMinimised: false };
    default: throw new RangeError(`Unknown preview action: ${event.type}`);
  }
}
