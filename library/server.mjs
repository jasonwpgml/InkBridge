#!/usr/bin/env node
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { htmlWarnings, injectOverlay, readContent, saveSnapshot } from './lib/content.mjs';
import { bookKind, CONVERTIBLE, convertDocument, isConvertible, OUTPUT_DIR, outputFor } from './lib/convert.mjs';
import { writeExport } from './lib/export.mjs';
import { writeInkPdf } from './lib/pdf-ink.mjs';
import { isIgnoredForWatch, PathError, resolveInside, toRelative } from './lib/paths.mjs';
import { isReviewId, publicReview, ReviewStore, validateLive, validateNavigate, validatePresence, ValidationError, writeAtomic } from './lib/store.mjs';

const CLIENT_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'client');
const DATA_DIR_NAME = '.pencil-review';
const COOKIE = 'pr_token';
const MAX_BODY = 4 * 1024 * 1024;
const MAX_IMPORT = 300 * 1024 * 1024;
// Files the iPad library brings in land here, then convert like any document dropped into the folder.
// Only documents that become page images: served HTML runs scripts on this origin, so it must come from the Mac user.
export const IMPORT_DIR = 'imported';
const IMPORTABLE = CONVERTIBLE;
const RELOAD_EXT = new Set(['.html', '.htm', '.css', '.js', '.mjs', '.json', '.svg', '.png', '.jpg', '.jpeg', '.gif', '.webp', '.avif', '.woff', '.woff2', '.ttf', '.otf']);
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif',
  '.webp': 'image/webp', '.avif': 'image/avif', '.ico': 'image/x-icon', '.woff': 'font/woff', '.woff2': 'font/woff2',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.txt': 'text/plain; charset=utf-8', '.md': 'text/markdown; charset=utf-8',
  '.pdf': 'application/pdf', '.mp4': 'video/mp4', '.webm': 'video/webm',
};
const CLIENT_FILES = { 'overlay.js': 'overlay.js', 'overlay.css': 'overlay.css', 'pen-test': 'pen-test.html', 'view': 'viewer.html' };

const isHtml = (rel) => /\.html?$/i.test(rel);

async function loadToken(dataDir, renew) {
  const file = path.join(dataDir, 'token');
  if (!renew) {
    try {
      const saved = (await fs.readFile(file, 'utf8')).trim();
      if (saved.length >= 20) return saved;
    } catch {
      // Created below.
    }
  }
  const token = crypto.randomBytes(18).toString('base64url');
  await writeAtomic(file, token + '\n');
  await fs.chmod(file, 0o600);
  return token;
}

function sameToken(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(b);
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

function cookieToken(req) {
  for (const part of (req.headers.cookie ?? '').split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === COOKIE) return v.join('=');
  }
  return null;
}

function send(res, status, body, type = 'text/plain; charset=utf-8', headers = {}) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers });
  res.end(body);
}

const sendJson = (res, status, value) => send(res, status, JSON.stringify(value), 'application/json; charset=utf-8');

// Clearing and saving act on one document; an empty or odd page must never mean "every review".
function requirePage(body) {
  const page = body?.page;
  if (typeof page !== 'string' || !page || page.length > 1024 || page.startsWith('/') || page.split('/').includes('..')) {
    throw new ValidationError('page');
  }
  return page;
}

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw new ValidationError('body too large');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new ValidationError('invalid JSON');
  }
}

// Streams an uploaded document into imported/ under a free name; it appears in the folder only once complete.
async function importFile(rootReal, dataDir, rawName, req) {
  const name = path.basename(String(rawName)).replace(/[\u0000-\u001f/\\:]/g, '').trim();
  const ext = path.extname(name).toLowerCase();
  if (!name || name.startsWith('.') || name.length > 200 || !IMPORTABLE.has(ext)) throw new ValidationError('unsupported file');
  const dir = path.join(rootReal, IMPORT_DIR);
  await fs.mkdir(dir, { recursive: true });
  const temp = path.join(dataDir, `import-${crypto.randomBytes(6).toString('hex')}`);
  const out = await fs.open(temp, 'w');
  let size = 0;
  try {
    for await (const chunk of req) {
      size += chunk.length;
      if (size > MAX_IMPORT) throw new ValidationError('file too large');
      await out.write(chunk);
    }
  } catch (err) {
    await out.close();
    await fs.rm(temp, { force: true });
    throw err;
  }
  await out.close();
  if (!size) {
    await fs.rm(temp, { force: true });
    throw new ValidationError('empty file');
  }
  const stem = name.slice(0, name.length - ext.length);
  for (let n = 1; ; n++) {
    const candidate = n === 1 ? name : `${stem} (${n})${ext}`;
    try {
      await fs.link(temp, path.join(dir, candidate));
      await fs.rm(temp);
      return `${IMPORT_DIR}/${candidate}`;
    } catch (err) {
      if (err.code !== 'EEXIST') throw err;
    }
  }
}

async function listConvertible(rootReal) {
  const out = [];
  async function walk(dir, rel) {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules' || (!rel && entry.name === OUTPUT_DIR)) continue;
      const childRel = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(path.join(dir, entry.name), childRel);
      else if (isConvertible(childRel)) out.push(childRel);
    }
  }
  await walk(rootReal, '');
  return out;
}

async function listHtml(rootReal) {
  const out = [];
  async function walk(dir, rel) {
    if (out.length >= 500) return;
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules') continue;
      const childRel = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(path.join(dir, entry.name), childRel);
      else if (isHtml(entry.name)) out.push(childRel);
    }
  }
  await walk(rootReal, '');
  return out.sort();
}

async function readTitle(file) {
  const handle = await fs.open(file, 'r');
  try {
    const { buffer, bytesRead } = await handle.read(Buffer.alloc(65536), 0, 65536, 0);
    const m = buffer.subarray(0, bytesRead).toString('utf8').match(/<title[^>]*>([^<]*)<\/title>/i);
    return m ? m[1].replace(/\s+/g, ' ').trim().slice(0, 200) : '';
  } finally {
    await handle.close();
  }
}

// Pages for the home screen and the iPad library: newest first, with how much ink each already has.
// A converted document also names its source file, its kind of book and its first page as the cover.
async function listPages(rootReal, store) {
  const pages = [];
  const converted = new RegExp(`^${OUTPUT_DIR}/(.+)/index\\.html$`);
  for (const rel of await listHtml(rootReal)) {
    const file = path.join(rootReal, rel);
    const [stat, title] = await Promise.all([fs.stat(file), readTitle(file).catch(() => '')]);
    const reviews = store.list({ page: rel });
    const source = rel.match(converted)?.[1] ?? null;
    const pageFiles = source ? await fs.readdir(path.join(rootReal, OUTPUT_DIR, source, 'pages')).catch(() => []) : [];
    const pngs = pageFiles.filter((f) => f.endsWith('.png')).sort();
    pages.push({
      path: rel,
      title,
      source,
      kind: source ? bookKind(source) : 'web',
      cover: pngs.length ? `${OUTPUT_DIR}/${source}/pages/${pngs[0]}` : null,
      pageCount: pngs.length || null,
      modifiedAt: stat.mtime.toISOString(),
      reviews: reviews.length,
      strokes: reviews.reduce((sum, r) => sum + r.strokes, 0),
      reviewedAt: reviews[0]?.updatedAt ?? null,
    });
  }
  return pages.sort((a, b) => b.modifiedAt.localeCompare(a.modifiedAt));
}

export function localAddresses(port, scheme = 'http') {
  let host = os.hostname();
  try {
    host = execFileSync('scutil', ['--get', 'LocalHostName'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || host;
  } catch {
    // Not macOS; os.hostname() is used.
  }
  const primary = `${scheme}://${host.endsWith('.local') ? host : `${host}.local`}:${port}`;
  const others = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const a of list ?? []) {
      if (a.family === 'IPv4' && !a.internal) others.push({ name, url: `${scheme}://${a.address}:${port}` });
    }
  }
  return { primary, others, local: `${scheme}://localhost:${port}` };
}

// The Mac's own name (System Settings → General → About), shown on its bookcase in the iPad library.
function computerName() {
  try {
    return execFileSync('scutil', ['--get', 'ComputerName'], { encoding: 'utf8', timeout: 2000 }).trim() || os.hostname();
  } catch {
    return os.hostname();
  }
}

export async function startServer({ root, port = 5173, host = '::', cert, key, renewToken = false, quiet = false } = {}) {
  const rootReal = await fs.realpath(path.resolve(root));
  const dataDir = path.join(rootReal, DATA_DIR_NAME);
  await fs.mkdir(dataDir, { recursive: true });
  const token = await loadToken(dataDir, renewToken);
  const store = new ReviewStore(dataDir);
  await store.init();
  const bootId = crypto.randomBytes(6).toString('hex');
  const name = computerName();
  let lastPresence = null;
  // Conversions run one at a time; the home screen shows what is pending or failed.
  const conversions = new Map(); // source rel → { status: 'waiting' | 'converting' | 'done' | 'failed', error?, output? }
  let converting = Promise.resolve();
  function queueConversion(rel) {
    const entry = conversions.get(rel);
    if (entry && (entry.status === 'waiting' || entry.status === 'converting')) return;
    conversions.set(rel, { status: 'waiting' });
    broadcast('convert', { source: rel, status: 'waiting' });
    converting = converting.then(async () => {
      conversions.set(rel, { status: 'converting' });
      broadcast('convert', { source: rel, status: 'converting' });
      try {
        const out = await convertDocument(rootReal, rel);
        conversions.set(rel, { status: 'done', output: out.output });
        if (!out.skipped) log(`  converted ${rel} → ${out.output}${out.pages ? ` (${out.pages} pages)` : ''}`);
      } catch (err) {
        if (err.code === 'ENOENT') {
          conversions.delete(rel);
          return;
        }
        conversions.set(rel, { status: 'failed', error: err.message });
        log(`  conversion failed ${rel}: ${err.message}`);
      }
      broadcast('convert', { source: rel, ...conversions.get(rel) });
    });
  }
  const clients = new Set();
  const log = quiet ? () => {} : (...a) => console.log(...a);

  function broadcast(event, data) {
    const msg = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(msg);
  }

  async function serveHtml(res, html, attrs) {
    for (const w of htmlWarnings(html)) log(`  warning ${attrs.page}: ${w}`);
    send(res, 200, injectOverlay(html, attrs), TYPES['.html']);
  }

  async function serveFile(res, real) {
    const ext = path.extname(real).toLowerCase();
    const data = await fs.readFile(real);
    res.writeHead(200, { 'Content-Type': TYPES[ext] ?? 'application/octet-stream', 'Cache-Control': 'no-cache', 'X-Content-Type-Options': 'nosniff' });
    res.end(data);
  }

  async function serveLive(res, urlPath) {
    let rel = toRelative(urlPath);
    const home = () => send(res, 200, fsSync.readFileSync(path.join(CLIENT_DIR, 'home.html')), TYPES['.html']);
    // The root is always the home screen; a folder's own index.html stays reachable by name.
    if (!rel) return home();
    let real = await resolveInside(rootReal, rel);
    if ((await fs.stat(real)).isDirectory()) {
      const indexRel = `${rel}/index.html`;
      try {
        real = await resolveInside(rootReal, indexRel);
        rel = indexRel;
      } catch {
        return home();
      }
    }
    if (!isHtml(rel)) return serveFile(res, real);
    const content = await readContent(rootReal, rel);
    if (!content) throw new PathError(404, 'not found');
    if (await saveSnapshot(dataDir, content, rel)) log(`  snapshot ${content.version} ${rel}`);
    await serveHtml(res, content.files.get(rel).toString('utf8'), { page: rel, version: content.version, mode: 'live', boot: bootId });
  }

  async function serveSnapshot(res, version, urlPath) {
    if (!/^[0-9a-f]{16}$/.test(version)) throw new PathError(404, 'not found');
    const snapRoot = path.join(dataDir, 'snapshots', version);
    const rel = toRelative(urlPath);
    let real;
    try {
      real = await resolveInside(snapRoot, rel);
    } catch {
      // Assets the snapshot did not capture fall back to the current file.
      real = await resolveInside(rootReal, rel);
    }
    if (!isHtml(rel)) return serveFile(res, real);
    await serveHtml(res, await fs.readFile(real, 'utf8'), { page: rel, version, mode: 'snapshot', boot: bootId });
  }

  async function api(req, res, parts, url) {
    const [, , , resource, id, action] = parts;
    if (resource === 'reviews' && !id && req.method === 'GET') {
      const num = (k) => (url.searchParams.has(k) ? Number(url.searchParams.get(k)) : undefined);
      return sendJson(res, 200, store.list({ page: url.searchParams.get('page') ?? undefined, version: url.searchParams.get('version') ?? undefined, width: num('w'), height: num('h') }));
    }
    if (resource === 'reviews' && id) {
      if (!isReviewId(id)) return sendJson(res, 400, { error: 'review id' });
      if (!action && req.method === 'GET') {
        const r = store.get(id);
        return r ? sendJson(res, 200, publicReview(r)) : sendJson(res, 404, { error: 'not found' });
      }
      if (action === 'ops' && req.method === 'POST') {
        const body = await readJson(req);
        const { revision, changed, added, removed } = await store.applyOps(id, body.meta, body.ops);
        if (changed) {
          const r = store.get(id);
          broadcast('review', { id, revision, page: r.page, contentVersion: r.contentVersion, viewport: r.viewport, added, removed });
        }
        return sendJson(res, 200, { revision, changed });
      }
      if (action === 'live' && req.method === 'POST') {
        broadcast('live', { review: id, ...validateLive(await readJson(req)) });
        res.writeHead(204, { 'Cache-Control': 'no-store' });
        return res.end();
      }
      if (action === 'export' && req.method === 'POST') {
        const r = store.get(id);
        if (!r) return sendJson(res, 404, { error: 'not found' });
        return sendJson(res, 200, await writeExport(dataDir, r));
      }
    }
    if (resource === 'pages' && req.method === 'GET' && !id) return sendJson(res, 200, await listPages(rootReal, store));
    if (resource === 'info' && req.method === 'GET') return sendJson(res, 200, { root: rootReal, importDir: IMPORT_DIR, name });
    if (resource === 'import' && req.method === 'POST') {
      const saved = await importFile(rootReal, dataDir, url.searchParams.get('name') ?? '', req);
      log(`  imported ${saved}`);
      return sendJson(res, 200, { path: saved, page: isConvertible(saved) ? outputFor(saved) : saved });
    }
    if (resource === 'conversions' && req.method === 'GET') {
      return sendJson(res, 200, [...conversions].filter(([, c]) => c.status !== 'done').map(([source, c]) => ({ source, ...c })));
    }
    if (resource === 'pages' && id === 'clear' && !action && req.method === 'POST') {
      const page = requirePage(await readJson(req));
      let strokes = 0;
      const reviews = store.list({ page });
      for (const { id: rid } of reviews) {
        const ids = store.get(rid).strokes.map((s) => s.id);
        if (!ids.length) continue;
        const r = await store.applyOps(rid, null, [{ opId: `o_${crypto.randomBytes(9).toString('base64url')}`, type: 'erase', strokeIds: ids }]);
        strokes += r.changed;
        const cur = store.get(rid);
        broadcast('review', { id: rid, revision: r.revision, page: cur.page, contentVersion: cur.contentVersion, viewport: cur.viewport, added: r.added, removed: r.removed });
      }
      log(`  cleared ${strokes} strokes from ${page}`);
      return sendJson(res, 200, { reviews: reviews.length, strokes });
    }
    if (resource === 'pages' && id === 'export' && !action && req.method === 'POST') {
      // Saved copies go to .pencil-review/saved/<document>/<time>[-page]/, one folder per review.
      const body = await readJson(req);
      const page = requirePage(body);
      const { review, state } = body;
      const reviews = (review ? [store.get(String(review))].filter(Boolean) : store.list({ page }).map((r) => store.get(r.id)))
        .filter((r) => r.page === page);
      const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      const folder = path.join(dataDir, 'saved', String(page).replace(/[\/]/g, '_'), state !== undefined ? `${stamp}-page` : stamp);
      let strokes = 0;
      for (const r of reviews) {
        const n = state === undefined ? r.strokes.length : r.strokes.filter((s) => (s.state ?? '') === state).length;
        if (!n) continue;
        await writeExport(dataDir, r, { dir: path.join(folder, r.id), state });
        strokes += n;
      }
      if (strokes) log(`  saved ${strokes} strokes of ${page} to ${path.relative(rootReal, folder)}`);
      return sendJson(res, 200, { strokes, dir: strokes ? path.relative(rootReal, folder) : null });
    }
    if (resource === 'pages' && id === 'pdf' && !action && req.method === 'POST') {
      // The original PDF (or the PDF Keynote/Pages made) with the ink drawn on; a copy stays in .pencil-review/saved/<document>/.
      const page = requirePage(await readJson(req));
      const source = path.basename(path.dirname(page));
      const name = `${source.slice(0, source.length - path.extname(source).length)} (필기).pdf`;
      const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
      const file = path.join(dataDir, 'saved', page.replace(/[\/]/g, '_'), `${stamp} ${name}`);
      const { strokes } = await writeInkPdf(rootReal, store, page, file);
      log(`  wrote ${strokes} strokes of ${page} to ${path.relative(rootReal, file)}`);
      return send(res, 200, await fs.readFile(file), 'application/pdf', {
        'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
        'X-Strokes': String(strokes),
        'X-Saved': encodeURIComponent(path.relative(rootReal, file)),
      });
    }
    if (resource === 'presence' && req.method === 'POST') {
      lastPresence = { ...validatePresence(await readJson(req)), at: new Date().toISOString() };
      broadcast('presence', lastPresence);
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      return res.end();
    }
    if (resource === 'presence' && req.method === 'GET') return sendJson(res, 200, lastPresence);
    if (resource === 'navigate' && req.method === 'POST') {
      broadcast('navigate', validateNavigate(await readJson(req)));
      res.writeHead(204, { 'Cache-Control': 'no-store' });
      return res.end();
    }
    if (resource === 'pen-tests' && req.method === 'POST') {
      const body = await readJson(req);
      const dir = path.join(dataDir, 'pen-tests');
      await fs.mkdir(dir, { recursive: true });
      const file = path.join(dir, `${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
      await writeAtomic(file, JSON.stringify({ receivedAt: new Date().toISOString(), userAgent: req.headers['user-agent'] ?? '', ...body }, null, 2));
      log(`  pen test saved ${path.relative(rootReal, file)}`);
      return sendJson(res, 200, { saved: path.relative(rootReal, file) });
    }
    return sendJson(res, 404, { error: 'unknown api' });
  }

  async function handle(req, res) {
    const url = new URL(req.url, 'http://x');
    const queryToken = url.searchParams.get('t');
    if (queryToken !== null) {
      if (!sameToken(queryToken, token)) return send(res, 401, '토큰이 맞지 않습니다. 서버가 출력한 주소로 여세요.');
      url.searchParams.delete('t');
      // Strict would drop the cookie on the first cross-site navigation from a QR or bookmark app; Lax keeps it for top-level GETs.
      return send(res, 303, '', undefined, {
        'Set-Cookie': `${COOKIE}=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000`,
        Location: url.pathname + url.search,
      });
    }
    // Home-screen icons hold nothing private and are fetched by iOS without the page's cookie.
    const icon = url.pathname.match(/^\/__pr\/(icon-(?:180|192|512)\.png)$/);
    if (icon && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'image/png', 'Cache-Control': 'max-age=86400' });
      return res.end(await fs.readFile(path.join(CLIENT_DIR, icon[1])));
    }
    const supplied = cookieToken(req) ?? req.headers['x-pr-token'];
    if (!supplied || !sameToken(supplied, token)) return send(res, 401, '토큰이 필요합니다. 서버가 출력한 주소(…?t=…)로 여세요.');

    // The cookie rides along on requests other sites' pages send; only this server's own pages (or the app, which sends no Origin) may change anything.
    const origin = req.headers.origin;
    if (req.method !== 'GET' && req.method !== 'HEAD' && origin !== undefined) {
      let sameHost = false;
      try { sameHost = new URL(origin).host === req.headers.host; } catch {}
      if (!sameHost) return send(res, 403, 'cross-origin request');
    }

    const parts = url.pathname.split('/');
    if (url.pathname === '/__pen-test') return serveFile(res, path.join(CLIENT_DIR, 'pen-test.html'));
    if (parts[1] !== '__pr') {
      if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'method not allowed');
      return serveLive(res, url.pathname);
    }
    if (parts[2] === 'events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write(`retry: 2000\nevent: hello\ndata: ${JSON.stringify({ boot: bootId })}\n\n`);
      clients.add(res);
      req.on('close', () => clients.delete(res));
      return;
    }
    if (parts[2] === 'api') return api(req, res, parts, url);
    if (parts[2] === 'snap') return serveSnapshot(res, parts[3] ?? '', parts.slice(4).join('/'));
    if (parts[2] === 'manifest.webmanifest' && parts.length === 3) {
      // A home-screen web app keeps its own cookies apart from Safari, so it starts from the token URL once.
      // Scripts in served pages could fetch() the manifest; only the browser's own manifest load gets the token.
      const dest = req.headers['sec-fetch-dest'];
      const manifest = {
        name: 'InkBridge 서재', short_name: '서재', lang: 'ko',
        start_url: dest === 'manifest' ? `/?t=${token}` : '/', scope: '/', display: 'standalone',
        background_color: '#f2f2f7', theme_color: '#0a63d6',
        icons: [192, 512].map((n) => ({ src: `/__pr/icon-${n}.png`, sizes: `${n}x${n}`, type: 'image/png' })),
      };
      return send(res, 200, JSON.stringify(manifest), 'application/manifest+json; charset=utf-8');
    }
    const client = CLIENT_FILES[parts[2]];
    if (client && parts.length === 3) {
      const file = path.join(CLIENT_DIR, client);
      return send(res, 200, await fs.readFile(file), TYPES[path.extname(file)]);
    }
    return send(res, 404, 'not found');
  }

  const listener = (req, res) => {
    handle(req, res).catch((err) => {
      if (err instanceof PathError || err instanceof ValidationError) {
        if (req.url.startsWith('/__pr/api/')) return sendJson(res, err.status, { error: err.message });
        return send(res, err.status, err.message);
      }
      if (err.code === 'ENOENT') return send(res, 404, 'not found');
      console.error(err);
      if (!res.headersSent) send(res, 500, 'internal error');
      else res.end();
    });
  };
  const server = cert && key
    ? https.createServer({ cert: fsSync.readFileSync(cert), key: fsSync.readFileSync(key) }, listener)
    : http.createServer(listener);

  const pending = new Set();
  let timer = null;
  const convertTimers = new Map();
  const watcher = fsSync.watch(rootReal, { recursive: true }, (_event, filename) => {
    if (!filename) return;
    const rel = filename.split(path.sep).join('/');
    if (isIgnoredForWatch(rel)) return;
    if (isConvertible(rel)) {
      // Saving a document fires several events; convert once it settles.
      clearTimeout(convertTimers.get(rel));
      convertTimers.set(rel, setTimeout(() => {
        convertTimers.delete(rel);
        fs.access(path.join(rootReal, rel)).then(() => queueConversion(rel), () => {});
      }, 800));
      return;
    }
    if (!RELOAD_EXT.has(path.extname(rel).toLowerCase())) return;
    pending.add(rel);
    clearTimeout(timer);
    timer = setTimeout(() => {
      const paths = [...pending];
      pending.clear();
      log(`  changed ${paths.join(', ')}`);
      broadcast('reload', { paths });
    }, 100);
  });
  const heartbeat = setInterval(() => {
    for (const res of clients) res.write(': ping\n\n');
  }, 25000);

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, resolve);
  });
  const actualPort = server.address().port;
  // Documents already in the folder are converted (or found up to date) in the background.
  for (const rel of await listConvertible(rootReal)) queueConversion(rel);
  const scheme = cert && key ? 'https' : 'http';

  async function close() {
    watcher.close();
    await converting;
    clearInterval(heartbeat);
    clearTimeout(timer);
    for (const res of clients) res.end();
    await new Promise((resolve) => server.close(resolve));
  }
  return { server, port: actualPort, token, rootReal, dataDir, store, close, scheme };
}

function parseArgs(argv) {
  const opts = { root: '.', port: 5173, host: '::' };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port') opts.port = Number(argv[++i]);
    else if (a === '--host') opts.host = argv[++i];
    else if (a === '--cert') opts.cert = argv[++i];
    else if (a === '--key') opts.key = argv[++i];
    else if (a === '--new-token') opts.renewToken = true;
    else if (a === '-h' || a === '--help') opts.help = true;
    else rest.push(a);
  }
  if (rest[0]) opts.root = rest[0];
  return opts;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log('사용법: node server.mjs <작업 폴더> [--port 5173] [--host ::] [--new-token] [--cert 파일 --key 파일]');
    process.exit(0);
  }
  const s = await startServer(opts).catch((err) => {
    if (err.code !== 'EADDRINUSE') throw err;
    console.error(`포트 ${opts.port}을 이미 다른 프로그램이 쓰고 있습니다. 서재 서버가 이미 켜져 있다면 그 주소를 그대로 쓰세요.`);
    console.error(`사용 중인 프로그램 확인: lsof -nP -iTCP:${opts.port} -sTCP:LISTEN   다른 포트로 실행: --port ${opts.port + 1}`);
    process.exit(1);
  });
  const { primary, others, local } = localAddresses(s.port, s.scheme);
  console.log(`InkBridge 서재 — ${s.rootReal}`);
  console.log(`\niPad 권장 주소 (이 주소만 계속 쓰세요):\n  ${primary}/?t=${s.token}`);
  console.log(`\n맥에서:\n  ${local}/?t=${s.token}`);
  if (others.length) {
    console.log('\n.local이 안 열릴 때 (다른 주소로 열면 그 주소의 미전송 필기와 공유되지 않습니다):');
    for (const o of others) console.log(`  ${o.url}/?t=${s.token}   (${o.name})`);
  }
  console.log(`\n입력 실험: /__pen-test   필기 데이터: ${path.join(s.rootReal, DATA_DIR_NAME)}`);
  console.log('HTML은 반드시 위 주소로 여세요. file://이나 AirDrop으로 열면 필기 레이어가 없습니다.\n');
  const stop = () => s.close().then(() => process.exit(0));
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}
