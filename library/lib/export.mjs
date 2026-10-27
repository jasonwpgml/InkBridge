import fs from 'node:fs/promises';
import path from 'node:path';
import { isPageSpace } from './pdf-ink.mjs';
import { publicReview, writeAtomic } from './store.mjs';

function bbox(points) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [x, y] of points) {
    minX = Math.min(minX, x); minY = Math.min(minY, y);
    maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  }
  return [minX, minY, maxX - minX, maxY - minY].map((v) => Math.round(v));
}

export function strokesSvg(review) {
  const width = review.viewport.width;
  const height = Math.max(review.viewport.height, ...review.strokes.flatMap((s) => s.points.map((p) => Math.ceil(p[1] + s.width * 2))));
  const paths = review.strokes.map((s) => {
    const d = s.points.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
    const avgPressure = s.points.reduce((sum, p) => sum + p[2], 0) / s.points.length;
    const w = s.tool === 'pen' ? s.width * (0.5 + avgPressure) : s.width;
    const opacity = s.tool === 'highlighter' ? ' stroke-opacity="0.35"' : '';
    return `  <path id="${s.id}" d="${d}" fill="none" stroke="${s.color}" stroke-width="${w.toFixed(2)}" stroke-linecap="round" stroke-linejoin="round"${opacity}/>`;
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">\n${paths.join('\n')}\n</svg>\n`;
}

export function reviewMarkdown(review, snapshotDir) {
  const lines = [
    `# Review ${review.id}`,
    '',
    `- Page: \`${review.page}\``,
    `- Content version: \`${review.contentVersion}\` (snapshot: \`${snapshotDir}\`)`,
    isPageSpace(review.viewport) && review.page.startsWith('converted/')
      ? '- Coordinates: page-image px (each page is 1600 px wide; the page number is the `#page=N` state)'
      : `- Viewport: ${review.viewport.width}×${review.viewport.height} CSS px`,
    `- Device: ${review.device || 'unknown'}`,
    `- Updated: ${review.updatedAt}, revision ${review.revision}, ${review.strokes.length} strokes`,
    '',
    'Unless the line above says page-image px, coordinates are document CSS px at the viewport above, measured on the reviewing device. Anchors and context were captured on that device while drawing; they describe the snapshot, not the current file. A page state (URL hash such as `#step=3`) means the stroke was drawn while the page showed that state; open the snapshot with that hash to see it.',
    '',
  ];
  review.strokes.forEach((s, i) => {
    const [x, y, w, h] = bbox(s.points);
    lines.push(`## ${i + 1}. ${s.tool} ${s.color} at (${x}, ${y}) ${w}×${h}${s.state ? ` — page state \`${s.state}\`` : ''}`);
    if (s.context) lines.push('', `Text near the stroke: “${s.context}”`);
    for (const a of s.anchors) lines.push(`- \`${a.selector}\` [${a.rect.map(Math.round).join(', ')}]: ${a.text || '(no text)'}`);
    lines.push('');
  });
  return lines.join('\n');
}

// `state` limits the export to one page of a dynamic document (its URL hash); `dir` overrides the folder.
export async function writeExport(dataDir, fullReview, { dir = path.join(dataDir, 'exports', fullReview.id), state } = {}) {
  const review = state === undefined ? fullReview : { ...fullReview, strokes: fullReview.strokes.filter((s) => (s.state ?? '') === state) };
  await fs.mkdir(dir, { recursive: true });
  const snapshotDir = path.join(dataDir, 'snapshots', review.contentVersion);
  const pub = publicReview(review);
  const json = { ...pub, strokes: pub.strokes.map((s) => ({ ...s, bbox: bbox(s.points) })) };
  await writeAtomic(path.join(dir, 'review.json'), JSON.stringify(json, null, 2));
  await writeAtomic(path.join(dir, 'strokes.svg'), strokesSvg(review));
  await writeAtomic(path.join(dir, 'REVIEW.md'), reviewMarkdown(review, snapshotDir));
  return { dir, files: ['review.json', 'strokes.svg', 'REVIEW.md'] };
}
