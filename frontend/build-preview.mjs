import { build } from 'vite';
import { createHash } from 'node:crypto';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const frontend = fileURLToPath(new URL('.', import.meta.url));
const destination = resolve(frontend, '..', 'site', 'preview');
const result = await build({
  configFile: false,
  root: join(frontend, 'preview'),
  base: './',
  build: {
    target: 'es2022',
    outDir: destination,
    emptyOutDir: true,
    modulePreload: false,
    minify: true,
  },
});
const modules = Object.keys(result.output.filter(item => item.type === 'chunk')
  .reduce((all, chunk) => Object.assign(all, chunk.modules), {}));
for (const name of ['main.js', 'render.js', 'events.js', 'state.js', 'style.css']) {
  if (!modules.some(id => id.replaceAll('\\', '/').endsWith(`/src/${name}`))) {
    throw new Error(`The website preview did not bundle the desktop app's ${name}.`);
  }
}

async function sourceFiles(folder) {
  const entries = await readdir(join(frontend, folder), { withFileTypes: true });
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? sourceFiles(join(folder, entry.name)) : join(folder, entry.name)))).flat();
}
const sources = {};
for (const path of [...await sourceFiles('src'), ...await sourceFiles('preview'), ...await sourceFiles('wailsjs'), 'build-preview.mjs', 'package.json', 'package-lock.json']) {
  const content = (await readFile(join(frontend, path), 'utf8')).replaceAll('\r\n', '\n');
  sources[path.split(sep).join('/')] = createHash('sha256').update(content).digest('hex');
}
const assets = {};
for (const item of result.output) {
  assets[item.fileName] = createHash('sha256').update(await readFile(join(destination, item.fileName))).digest('hex');
}
await writeFile(join(destination, 'source-manifest.json'), JSON.stringify({
  description: 'Built from the desktop frontend; only native calls are replaced with in-memory example behavior.',
  sources, assets,
}, null, 2) + '\n');
console.log(`Shared app preview generated in ${relative(frontend, destination)}.`);
