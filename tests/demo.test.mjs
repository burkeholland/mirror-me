import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { initialState, reduce, DEFAULT_NOTE, formatTime } from '../demo.mjs';

test('a connection is not mirroring until the demo completes its connection stage', () => {
  let state = reduce(initialState(), { type: 'start' });
  assert.equal(state.phase, 'connecting');
  state = reduce(state, { type: 'connected' });
  assert.equal(state.phase, 'mirroring');
});
test('cancelling blocks a late connection completion', () => {
  const stopped = reduce(reduce(initialState(), { type: 'start' }), { type: 'stop' });
  assert.equal(reduce(stopped, { type: 'connected' }).phase, 'idle');
});
test('content, orientation, and notes survive a reconnect', () => {
  let state = reduce(initialState(), { type: 'content', value: 'notes' });
  state = reduce(state, { type: 'rotate' });
  state = reduce(state, { type: 'note', value: '<img src=x> A real note' });
  state = reduce(state, { type: 'start' });
  assert.equal(state.landscape, true);
  assert.equal(state.content, 'notes');
  assert.equal(state.note, '<img src=x> A real note');
});
test('reduced motion begins paused and pausing holds the stopwatch', () => {
  let state = initialState(true);
  assert.equal(reduce(state, { type: 'tick' }).seconds, 0);
  state = reduce(state, { type: 'motion' });
  state = reduce(state, { type: 'tick' });
  assert.equal(state.seconds, 1);
  assert.equal(reduce(reduce(state, { type: 'pause' }), { type: 'tick' }).seconds, 1);
});
test('reset creates a clean demo and notes are bounded by complete code points', () => {
  assert.equal(initialState().note, DEFAULT_NOTE);
  const state = reduce(initialState(), { type: 'note', value: '\u{1f4f1}'.repeat(400) });
  assert.equal(Array.from(state.note).length, 280);
});
test('stopwatch formatting and rollover remain bounded', () => {
  assert.equal(formatTime(125), '02:05');
  assert.equal(reduce({ ...initialState(), seconds: 3599 }, { type: 'tick' }).seconds, 0);
});
test('unknown interactions cannot silently invent a demo state', () => {
  assert.throws(() => reduce(initialState(), { type: 'content', value: 'camera' }));
  assert.throws(() => reduce(initialState(), { type: 'unsupported' }));
});
test('the page uses project-relative assets, an explicit prerelease, and truthful limits', async () => {
  const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');
  assert.match(html, /releases\/download\/v0\.1\.0-preview\.1\/MirrorMe-windows-x64\.zip/);
  assert.match(html, /Interactive simulation/);
  assert.match(html, /113 MB/);
  assert.match(html, /Physical-iPhone mirroring/);
  assert.doesNotMatch(html, /releases\/latest|src="https:|href="\/(?:assets|style)/);
  assert.match(html, /connect-src 'none'/);
});
