// Writes a PDF, slide deck or Word document back out as a PDF with its ink drawn over the original pages.
// Ink is stored in screen coordinates of the converted paged HTML, so this undoes that page's layout.
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { OUTPUT_DIR, SOURCE_PDF } from './convert.mjs';
import { readContent } from './content.mjs';
import { ValidationError } from './store.mjs';

const run = promisify(execFile);
const TOOL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const WRITER = path.join(TOOL_DIR, 'bin', 'pdf-ink');
const WRITER_SOURCE = path.join(TOOL_DIR, 'scripts', 'pdf-ink.swift');

async function ensureWriter() {
  const [bin, src] = await Promise.all([fs.stat(WRITER).catch(() => null), fs.stat(WRITER_SOURCE)]);
  if (bin && bin.mtimeMs >= src.mtimeMs) return;
  await fs.mkdir(path.dirname(WRITER), { recursive: true });
  await run('xcrun', ['swiftc', '-O', WRITER_SOURCE, '-o', WRITER], { timeout: 300000 });
}

// Where pagedHtml puts a page image of w×h px in a viewport: below the 48px header and 12px padding,
// centred, shrunk to fit the width (minus padding) and the height (100vh - 72px), never enlarged.
export function pageLayout(viewport, w, h) {
  const scale = Math.min(1, (viewport.width - 24) / w, (viewport.height - 72) / h);
  return { x: (viewport.width - w * scale) / 2, y: 60, scale };
}

async function pngSize(file) {
  const handle = await fs.open(file, 'r');
  try {
    const { buffer } = await handle.read(Buffer.alloc(24), 0, 24, 0);
    return [buffer.readUInt32BE(16), buffer.readUInt32BE(20)];
  } finally {
    await handle.close();
  }
}

// The PDF the converted pages were rendered from, or null for documents that are not paged.
export function sourcePdf(rootReal, page) {
  const source = String(page).match(new RegExp(`^${OUTPUT_DIR}/(.+)/index\\.html$`))?.[1];
  if (!source) return null;
  return path.extname(source).toLowerCase() === '.pdf'
    ? path.join(rootReal, source)
    : path.join(rootReal, OUTPUT_DIR, source, SOURCE_PDF);
}

// Draws the ink of the current version of `page` (every screen size it was written at) onto `out`.
export async function writeInkPdf(rootReal, store, page, out) {
  const pdf = sourcePdf(rootReal, page);
  if (!pdf || !(await fs.stat(pdf).catch(() => null))) throw new ValidationError('PDF로 내보낼 수 있는 문서가 아닙니다');
  const pagesDir = path.join(rootReal, path.dirname(page), 'pages');
  const { version } = await readContent(rootReal, page);
  const sizes = new Map();
  const pages = {};
  let strokes = 0;
  for (const { id } of store.list({ page, version })) {
    const review = store.get(id);
    for (const s of review.strokes) {
      const n = Number(new URLSearchParams((s.state ?? '').replace(/^#/, '')).get('page')) || 1;
      const file = path.join(pagesDir, `${String(n).padStart(3, '0')}.png`);
      if (!sizes.has(n)) sizes.set(n, await pngSize(file).catch(() => null));
      const size = sizes.get(n);
      if (!size) continue;
      const { x, y, scale } = pageLayout(review.viewport, size[0], size[1]);
      const unit = scale * size[0];
      (pages[n] ??= []).push({
        tool: s.tool, color: s.color, kind: s.kind, width: s.width / unit,
        points: s.points.map((p) => [(p[0] - x) / unit, (p[1] - y) / unit, p[2]]),
      });
      strokes++;
    }
  }
  await ensureWriter();
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'pdf-ink-'));
  try {
    const json = path.join(tmp, 'strokes.json');
    const pdfOut = path.join(tmp, 'out.pdf');
    await fs.writeFile(json, JSON.stringify({ pages }));
    await run(WRITER, [pdf, pdfOut, json], { timeout: 300000 });
    await fs.mkdir(path.dirname(out), { recursive: true });
    await fs.copyFile(pdfOut, out);
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
  return { strokes, pages: Object.keys(pages).length };
}
