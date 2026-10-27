import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { isInside, toRelative } from './paths.mjs';

const MAX_FILES = 200;
const HTML_REF = /\b(?:src|href|poster)\s*=\s*["']([^"']+)["']/gi;
const CSS_REF = /url\(\s*["']?([^"')]+)["']?\s*\)|@import\s+["']([^"']+)["']/gi;

// Local files an HTML or CSS file pulls in, as root-relative paths.
export function extractRefs(text, fromRel, kind) {
  const refs = [];
  const re = kind === 'css' ? CSS_REF : HTML_REF;
  for (const m of text.matchAll(re)) {
    const raw = (m[1] ?? m[2]).trim().split(/[?#]/)[0];
    if (!raw || /^[a-z][a-z0-9+.-]*:/i.test(raw) || raw.startsWith('//')) continue;
    const joined = raw.startsWith('/') ? raw : path.posix.join(path.posix.dirname(fromRel), raw);
    const normalized = path.posix.normalize(joined);
    if (normalized.startsWith('..')) continue;
    try {
      refs.push(toRelative(normalized));
    } catch {
      // Hidden or malformed references are not part of the snapshot.
    }
  }
  return refs;
}

// Hashes the page plus every local file it references (HTML attributes, CSS url()/@import).
// Scripts' runtime fetches and fonts loaded from JS are not covered.
export async function readContent(rootReal, pageRel) {
  const files = new Map();
  const queue = [pageRel];
  while (queue.length && files.size < MAX_FILES) {
    const rel = queue.shift();
    if (files.has(rel)) continue;
    const abs = path.resolve(rootReal, rel);
    if (!isInside(rootReal, abs)) continue;
    let real, data;
    try {
      real = await fs.realpath(abs);
      if (!isInside(rootReal, real)) continue;
      data = await fs.readFile(real);
    } catch {
      continue;
    }
    files.set(rel, data);
    const ext = path.extname(rel).toLowerCase();
    if (ext === '.html' || ext === '.htm') queue.push(...extractRefs(data.toString('utf8'), rel, 'html'));
    else if (ext === '.css') queue.push(...extractRefs(data.toString('utf8'), rel, 'css'));
  }
  if (!files.has(pageRel)) return null;
  const hash = crypto.createHash('sha256');
  for (const rel of [...files.keys()].sort()) {
    hash.update(rel).update('\0').update(files.get(rel)).update('\0');
  }
  return { version: hash.digest('hex').slice(0, 16), files };
}

export async function saveSnapshot(dataDir, content, pageRel) {
  const dir = path.join(dataDir, 'snapshots', content.version);
  try {
    await fs.access(path.join(dir, 'manifest.json'));
    return false;
  } catch {
    // Not saved yet.
  }
  for (const [rel, data] of content.files) {
    const target = path.join(dir, rel);
    await fs.mkdir(path.dirname(target), { recursive: true });
    await fs.writeFile(target, data);
  }
  const manifest = { version: content.version, page: pageRel, files: [...content.files.keys()], savedAt: new Date().toISOString() };
  await fs.writeFile(path.join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  return true;
}

export function injectOverlay(html, attrs) {
  const data = Object.entries(attrs).map(([k, v]) => ` data-${k}="${String(v).replace(/[&"<>]/g, (c) => `&#${c.charCodeAt(0)};`)}"`).join('');
  const tag = `<link rel="stylesheet" href="/__pr/overlay.css"><script src="/__pr/overlay.js" defer${data}></script>`;
  const idx = html.toLowerCase().lastIndexOf('</body>');
  return idx === -1 ? html + tag : html.slice(0, idx) + tag + html.slice(idx);
}

export function htmlWarnings(html) {
  const warnings = [];
  if (/<meta[^>]+http-equiv\s*=\s*["']?content-security-policy/i.test(html)) warnings.push('CSP meta tag may block the overlay');
  if (/<base\s[^>]*href/i.test(html)) warnings.push('<base href> may break overlay paths');
  return warnings;
}
