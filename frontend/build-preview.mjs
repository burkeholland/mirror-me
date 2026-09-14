import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFile, readdir, readFile, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const frontend = fileURLToPath(new URL('.', import.meta.url));
const destination = resolve(frontend, '..', 'site', 'assets');
const review = resolve(frontend, '..', 'build', 'ui-review');
const result = spawnSync(process.execPath, [join(frontend, 'tests', 'browser-review.mjs'), review], {
  cwd: frontend, stdio: 'inherit',
});
if (result.error) throw result.error;
if (result.status !== 0) throw new Error(`Screenshot generation failed (${result.status ?? result.signal}).`);

async function sourceFiles(folder) {
  const entries = await readdir(join(frontend, folder), { withFileTypes: true });
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? sourceFiles(join(folder, entry.name)) : join(folder, entry.name)))).flat();
}
const sources = {};
for (const path of [
  ...await sourceFiles('src'), ...await sourceFiles('wailsjs'),
  'tests/browser-review.mjs', 'tests/preview.html', 'tests/preview.mjs', 'tests/fixtures.mjs',
  'build-preview.mjs', 'package.json', 'package-lock.json',
]) {
  const content = (await readFile(join(frontend, path), 'utf8')).replaceAll('\r\n', '\n');
  sources[path.split(sep).join('/')] = createHash('sha256').update(content).digest('hex');
}
const assets = {};
for (const theme of ['light', 'dark']) {
  const name = `app-${theme}.png`;
  await copyFile(join(review, `website-${theme}.png`), join(destination, name));
  assets[name] = createHash('sha256').update(await readFile(join(destination, name))).digest('hex');
}
await writeFile(join(destination, 'app-screenshots.json'), JSON.stringify({
  description: 'Static screenshots of the desktop frontend, rendered with example data in Edge.',
  sources, assets,
}, null, 2) + '\n');
console.log('Static app screenshots generated in site\\assets; no interactive app is shipped to the website.');
