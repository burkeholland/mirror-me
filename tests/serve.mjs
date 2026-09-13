import { createServer } from 'node:http';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import { extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const mime = { '.html': 'text/html', '.css': 'text/css', '.js': 'text/javascript', '.mjs': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain' };

export async function startServer(port = 0) {
  const base = '/mirror-me/';
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      if (!pathname.startsWith(base)) {
        response.writeHead(404).end('Not found');
        return;
      }
      const path = resolve(join(root, pathname.slice(base.length) || 'index.html'));
      if (!path.startsWith(root + sep)) {
        response.writeHead(403).end('Forbidden');
        return;
      }
      const body = await readFile(path);
      response.writeHead(200, { 'Content-Type': `${mime[extname(path)] || 'application/octet-stream'}; charset=utf-8`, 'Cache-Control': 'no-store' });
      response.end(request.method === 'HEAD' ? undefined : body);
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'EISDIR') console.error(error);
      response.writeHead(error.code === 'ENOENT' || error.code === 'EISDIR' ? 404 : 500).end('Unable to read page');
    }
  });
  server.listen(port, '127.0.0.1');
  await once(server, 'listening');
  return { server, url: `http://127.0.0.1:${server.address().port}${base}` };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const { url } = await startServer(Number(process.argv[2]) || 0);
  console.log(url);
}
