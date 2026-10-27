// Turns documents dropped into the served folder into pages this tool can show:
// PDF → page images in a paged HTML file; PowerPoint/Keynote → PDF via Keynote; Word/Pages → PDF via Pages
// (textutil HTML when Pages cannot open it). Output goes to converted/<source path>/index.html.
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const TOOL_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const RENDERER = path.join(TOOL_DIR, 'bin', 'pdf-pages');
const RENDERER_SOURCE = path.join(TOOL_DIR, 'scripts', 'pdf-pages.swift');
export const OUTPUT_DIR = 'converted';
const KEYNOTE = new Set(['.pptx', '.ppt', '.key']);
const PAGES = new Set(['.docx', '.doc', '.rtf', '.odt', '.pages']);
const TEXTUTIL = new Set(['.docx', '.doc', '.rtf', '.odt']);
export const CONVERTIBLE = new Set(['.pdf', ...KEYNOTE, ...PAGES]);
const PAGE_WIDTH = 1600;
const STAMP = '.pencil-source.json';

// What kind of book a document makes on the iPad library shelf.
export function bookKind(sourceRel) {
  const ext = path.extname(sourceRel).toLowerCase();
  if (ext === '.pdf') return 'pdf';
  if (KEYNOTE.has(ext)) return 'slides';
  if (PAGES.has(ext)) return 'doc';
  return 'web';
}

export const isConvertible = (rel) => CONVERTIBLE.has(path.extname(rel).toLowerCase()) && !rel.split('/').includes(OUTPUT_DIR);
export const outputFor = (rel) => `${OUTPUT_DIR}/${rel}/index.html`;

async function ensureRenderer() {
  const [bin, src] = await Promise.all([fs.stat(RENDERER).catch(() => null), fs.stat(RENDERER_SOURCE)]);
  if (bin && bin.mtimeMs >= src.mtimeMs) return;
  await fs.mkdir(path.dirname(RENDERER), { recursive: true });
  await run('xcrun', ['swiftc', '-O', RENDERER_SOURCE, '-o', RENDERER], { timeout: 300000 });
}

// Asks Keynote or Pages to export the document as PDF. macOS asks once for permission to control the app.
async function exportWithApp(bundleId, input, output) {
  const script = `on run argv
  set inFile to POSIX file (item 1 of argv)
  set outFile to POSIX file (item 2 of argv)
  tell application id "${bundleId}"
    set d to open inFile
    export d to outFile as PDF
    close d saving no
  end tell
end run`;
  await run('osascript', ['-e', script, input, output], { timeout: 180000 });
}

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`);

// One PDF page per screen, fitted to it; the page number lives in the URL hash so ink, follow and sync work per page.
export function pagedHtml(title, sizes) {
  const pages = JSON.stringify(sizes.map(([w, h], i) => ({ src: `pages/${String(i + 1).padStart(3, '0')}.png`, w, h })));
  return `<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)}</title>
<style>
  :root { color-scheme: light dark; --bg: #e5e5ea; --bar: rgba(255, 255, 255, 0.92); --fg: #1c1c1e; --muted: #6e6e73; }
  @media (prefers-color-scheme: dark) { :root { --bg: #111; --bar: rgba(28, 28, 30, 0.92); --fg: #f2f2f7; --muted: #98989d; } }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.3 -apple-system, system-ui, sans-serif; }
  header { display: flex; align-items: center; gap: 8px; height: 48px; padding: 0 12px; background: var(--bar); }
  header h1 { flex: 1; min-width: 0; margin: 0; font-size: 15px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  header button { min-width: 44px; min-height: 40px; border: 0; border-radius: 10px; background: transparent; color: inherit; font: inherit; font-size: 20px; }
  header button:disabled { opacity: 0.3; }
  #num { color: var(--muted); font-variant-numeric: tabular-nums; }
  main { display: grid; place-items: start center; padding: 12px; }
  img { display: block; max-width: 100%; max-height: calc(100vh - 72px); width: auto; height: auto; background: #fff; box-shadow: 0 1px 6px rgba(0, 0, 0, 0.2); }
</style>
</head>
<body>
<header>
  <h1>${esc(title)}</h1>
  <button type="button" id="prev" aria-label="이전 페이지">‹</button>
  <span id="num"></span>
  <button type="button" id="next" aria-label="다음 페이지">›</button>
</header>
<main><img id="page" alt=""></main>
<script>
(() => {
  const pages = ${pages};
  const img = document.getElementById('page');
  let current = 0;
  const fromHash = () => Math.min(pages.length, Math.max(1, Number(new URLSearchParams(location.hash.slice(1)).get('page')) || 1)) - 1;
  function show(i) {
    current = Math.min(pages.length - 1, Math.max(0, i));
    const p = pages[current];
    img.width = p.w;
    img.height = p.h;
    img.src = p.src;
    img.alt = (current + 1) + '쪽';
    document.getElementById('num').textContent = (current + 1) + ' / ' + pages.length;
    document.getElementById('prev').disabled = current === 0;
    document.getElementById('next').disabled = current === pages.length - 1;
    for (const n of [current - 1, current + 1]) if (pages[n]) new Image().src = pages[n].src;
    if (fromHash() !== current || !location.hash) location.hash = 'page=' + (current + 1);
  }
  document.getElementById('prev').addEventListener('click', () => show(current - 1));
  document.getElementById('next').addEventListener('click', () => show(current + 1));
  document.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight' || e.key === 'PageDown') show(current + 1);
    if (e.key === 'ArrowLeft' || e.key === 'PageUp') show(current - 1);
  });
  // A one-finger horizontal swipe turns the page; the pencil is left for ink.
  let start = null;
  addEventListener('touchstart', (e) => {
    const t = e.touches[0];
    start = e.touches.length === 1 && t.touchType !== 'stylus' && (!visualViewport || visualViewport.scale <= 1.01) ? [t.clientX, t.clientY] : null;
  }, { passive: true });
  addEventListener('touchend', (e) => {
    if (!start) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - start[0];
    if (Math.abs(dx) > 60 && Math.abs(dx) > 2 * Math.abs(t.clientY - start[1])) show(current + (dx < 0 ? 1 : -1));
    start = null;
  });
  addEventListener('hashchange', () => fromHash() !== current && show(fromHash()));
  show(fromHash());
})();
</script>
</body>
</html>
`;
}

export async function convertDocument(rootReal, rel) {
  const source = path.join(rootReal, rel);
  const stat = await fs.stat(source);
  const outDir = path.join(rootReal, OUTPUT_DIR, rel);
  const stampFile = path.join(outDir, STAMP);
  try {
    const stamp = JSON.parse(await fs.readFile(stampFile, 'utf8'));
    if (stamp.mtimeMs === stat.mtimeMs && stamp.size === stat.size) return { skipped: true, output: outputFor(rel) };
  } catch {
    // Not converted yet.
  }
  const ext = path.extname(rel).toLowerCase();
  const title = path.basename(rel);
  const tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'pencil-review-'));
  try {
    let pdf = source;
    if (KEYNOTE.has(ext) || PAGES.has(ext)) {
      pdf = path.join(tmp, 'export.pdf');
      try {
        await exportWithApp(KEYNOTE.has(ext) ? 'com.apple.Keynote' : 'com.apple.Pages', source, pdf);
      } catch (err) {
        if (!TEXTUTIL.has(ext)) throw new Error(`${KEYNOTE.has(ext) ? 'Keynote' : 'Pages'}로 PDF를 만들지 못했습니다: ${err.message.split('\n')[0]}`);
        // Text documents still work without Pages, as reflowing HTML.
        await fs.rm(outDir, { recursive: true, force: true });
        await fs.mkdir(outDir, { recursive: true });
        await run('textutil', ['-convert', 'html', '-title', title, '-output', path.join(outDir, 'index.html'), source], { timeout: 60000 });
        await fs.writeFile(stampFile, JSON.stringify({ mtimeMs: stat.mtimeMs, size: stat.size, via: 'textutil' }));
        return { output: outputFor(rel), via: 'textutil' };
      }
    }
    await ensureRenderer();
    const pagesDir = path.join(tmp, 'pages');
    const { stdout } = await run(RENDERER, [pdf, pagesDir, String(PAGE_WIDTH)], { timeout: 300000, maxBuffer: 16 * 1024 * 1024 });
    const sizes = JSON.parse(stdout);
    if (!sizes.length) throw new Error('PDF에 페이지가 없습니다');
    // Replace the old output only once the new one is complete.
    await fs.rm(outDir, { recursive: true, force: true });
    await fs.mkdir(outDir, { recursive: true });
    await fs.rename(pagesDir, path.join(outDir, 'pages')).catch(async (err) => {
      if (err.code !== 'EXDEV') throw err;
      await fs.cp(pagesDir, path.join(outDir, 'pages'), { recursive: true });
    });
    await fs.writeFile(path.join(outDir, 'index.html'), pagedHtml(title, sizes));
    await fs.writeFile(stampFile, JSON.stringify({ mtimeMs: stat.mtimeMs, size: stat.size, pages: sizes.length }));
    return { output: outputFor(rel), pages: sizes.length };
  } finally {
    await fs.rm(tmp, { recursive: true, force: true });
  }
}
