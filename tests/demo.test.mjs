import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';

const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('the app preview is static, without an embedded app or sample toolbar', async () => {
  const script = await readFile(new URL('../app.mjs', import.meta.url), 'utf8');
  const styles = await readFile(new URL('../style.css', import.meta.url), 'utf8');
  assert.match(html, /src="\.\/assets\/app-light\.png"/);
  assert.match(html, /src="\.\/assets\/app-dark\.png"/);
  assert.match(html, /Static screenshots/);
  const preview = html.split('<section id="demo"')[1].split('</section>')[0];
  assert.doesNotMatch(preview, /<(?:iframe|button|input|select|textarea|a)\b|tabindex=/);
  assert.doesNotMatch(html, /Sample image|demo-controls|view-controls|motion-control|id="(?:rotate|motion|reset)"/);
  assert.doesNotMatch(script, /postMessage|contentWindow|setInterval|setTimeout|#demo|#app-preview/);
  assert.doesNotMatch(styles, /demo-controls|view-controls|motion-control|@keyframes|preview-error|window-placeholder/);
  assert.match(html, /frame-src 'none'; connect-src 'none'/);
  await assert.rejects(readFile(new URL('../preview/index.html', import.meta.url)), { code: 'ENOENT' });
});

test('the landing page is concise and excludes the removed section and runtime names', () => {
  assert.match(html, /<h1 id="headline">Mirror your iPhone<br>to Windows\.<\/h1>/);
  assert.doesNotMatch(html, /ux\s*play|About this preview|details-section|<details\b|Simulated connection|More room|A little perspective/i);
  const words = html.split('<body>')[1].replace(/<svg\b[\s\S]*?<\/svg>/g, '')
    .replace(/<[^>]+>/g, ' ').replace(/&[a-z0-9#]+;/gi, ' ').trim().split(/\s+/).length;
  assert.ok(words <= 180, `Keep the page concise (${words} words)`);
});

test('the page links the self-contained preview and its sources without retired downloads', () => {
  assert.match(html, /17\.9 MB executable\.<\/strong> Built-in receiver\./);
  assert.match(html, /href="https:\/\/github\.com\/burkeholland\/mirror-me\/releases\/download\/v0\.2\.3-preview\.1\/MirrorMe-0\.2\.3-windows-x64\.zip"/);
  assert.match(html, /href="https:\/\/github\.com\/burkeholland\/mirror-me\/releases\/tag\/v0\.2\.3-preview\.1"/);
  assert.match(html, /Source, licenses &amp; checksums/);
  assert.doesNotMatch(html, /Windows download not yet available|v0\.1\.0|separate receiver setup/);
  assert.match(html, /Unsigned/);
  assert.doesNotMatch(html, /releases\/latest|src="https:/);
});

test('website notices preserve the complete frontend license texts without retired runtime instructions', async () => {
  const notices = await readFile(new URL('../assets/NOTICE.txt', import.meta.url), 'utf8');
  const appNotices = await readFile(new URL('../../THIRD-PARTY-NOTICES.md', import.meta.url), 'utf8');
  const licenseTexts = text => [...text.matchAll(/```text\n([\s\S]*?)```/g)].map(match => match[1]);
  const websiteLicenses = licenseTexts(notices.replaceAll('\r\n', '\n'));
  assert.equal(websiteLicenses.length, 3);
  assert.deepEqual(websiteLicenses, licenseTexts(appNotices.replaceAll('\r\n', '\n')));
  assert.match(notices, /Postrboard CSS 2\.0\.0/);
  assert.match(notices, /Lucide 1\.39\.0/);
  assert.doesNotMatch(notices + appNotices, /legacy-download|Legacy preview|receiver.runtime\.json|build-receiver\.ps1/);
});

test('the website exposes the application privacy notice', async () => {
  assert.match(html, /href="https:\/\/github\.com\/burkeholland\/mirror-me\/blob\/main\/PRIVACY\.md">Privacy<\/a>/);
  const privacy = await readFile(new URL('../../PRIVACY.md', import.meta.url), 'utf8');
  assert.match(privacy, /Verbose logging is off by default/);
  assert.match(privacy, /optional\s+pairing PIN/);
  assert.match(privacy, /does not automatically send these files/);
});

test('static app screenshots match the current frontend sources', async () => {
  const assetsRoot = new URL('../assets/', import.meta.url);
  const manifest = JSON.parse(await readFile(new URL('app-screenshots.json', assetsRoot), 'utf8'));
  const frontend = new URL('../../frontend/', import.meta.url);
  const files = [
    'tests/browser-review.mjs', 'tests/preview.html', 'tests/preview.mjs', 'tests/fixtures.mjs',
    'build-preview.mjs', 'package.json', 'package-lock.json',
  ];
  async function collect(directory) {
    for (const file of await readdir(new URL(directory, frontend), { withFileTypes: true })) {
      if (file.isDirectory()) await collect(`${directory}${file.name}/`);
      else files.push(`${directory}${file.name}`);
    }
  }
  await collect('src/');
  await collect('wailsjs/');
  assert.deepEqual(Object.keys(manifest.sources).sort(), files.sort(), 'Regenerate screenshots when app inputs change');
  for (const [path, hash] of Object.entries(manifest.sources)) {
    const source = (await readFile(new URL(path, frontend), 'utf8')).replaceAll('\r\n', '\n');
    assert.equal(createHash('sha256').update(source).digest('hex'), hash, `Regenerate stale screenshot source: ${path}`);
  }
  assert.deepEqual(Object.keys(manifest.assets).sort(), ['app-dark.png', 'app-light.png']);
  for (const [path, hash] of Object.entries(manifest.assets)) {
    const image = await readFile(new URL(path, assetsRoot));
    assert.equal(createHash('sha256').update(image).digest('hex'), hash, `Screenshot changed: ${path}`);
    assert.equal(image.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
    assert.equal(image.readUInt32BE(16), 1040);
    assert.equal(image.readUInt32BE(20), 760);
  }
});
