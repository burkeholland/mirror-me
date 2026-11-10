import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const lock = JSON.parse(await readFile(new URL('../../frontend/package-lock.json', import.meta.url), 'utf8'));
assert.equal(lock.lockfileVersion, 3);
const cutoff = Date.now() - 7 * 24 * 60 * 60 * 1000;
const metadata = new Map();
let checked = 0;
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path) continue;
  assert.ok(entry.version && entry.integrity && entry.resolved, `Incomplete lock entry: ${path}`);
  const name = path.split('node_modules/').at(-1);
  if (!metadata.has(name)) {
    const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}`, {
      signal: AbortSignal.timeout(60000),
    });
    assert.ok(response.ok, `Cannot verify release age for ${name}: HTTP ${response.status}`);
    metadata.set(name, await response.json());
  }
  const published = Date.parse(metadata.get(name).time?.[entry.version]);
  assert.ok(Number.isFinite(published) && published <= cutoff,
    `${name}@${entry.version} must have a verified publication date at least seven days ago`);
  checked++;
}
assert.ok(checked > 0, 'No locked dependencies were checked');
console.log(`Verified ${checked} locked npm versions are at least seven days old. Lockfile unchanged.`);
