import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { promisify } from 'node:util';
import { readContent } from '../lib/content.mjs';
import { convertDocument } from '../lib/convert.mjs';
import { pageLayout } from '../lib/pdf-ink.mjs';
import { startServer } from '../server.mjs';

const run = promisify(execFile);
const RENDERER = path.join(import.meta.dirname, '..', 'bin', 'pdf-pages');

// One 300×400 pt page with a blue box from (50, 50) to (250, 350).
function boxPdf() {
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Contents 4 0 R >>',
    '<< /Length 35 >>\nstream\n0 0 1 rg 50 50 200 300 re f\nendstream',
  ];
  let out = '%PDF-1.4\n';
  const offsets = [];
  objs.forEach((o, i) => {
    offsets.push(out.length);
    out += `${i + 1} 0 obj\n${o}\nendobj\n`;
  });
  const xref = out.length;
  out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`;
  out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return out;
}

// Renders page 1 at 1 px per pt and returns a pixel reader (top-left origin) via an uncompressed BMP from sips.
async function pixels(pdf, dir) {
  await run(RENDERER, [pdf, dir, '300']);
  const bmp = path.join(dir, 'page.bmp');
  await run('sips', ['-s', 'format', 'bmp', path.join(dir, '001.png'), '--out', bmp]);
  const b = await fs.readFile(bmp);
  const offset = b.readUInt32LE(10), width = b.readInt32LE(18), height = b.readInt32LE(22), bytes = b.readUInt16LE(28) / 8;
  const stride = Math.ceil((width * bytes) / 4) * 4;
  return (x, y) => {
    const row = height > 0 ? height - 1 - y : y;
    const i = offset + row * stride + x * bytes;
    return [b[i + 2], b[i + 1], b[i]];
  };
}

describe('pdf export', () => {
  let root, s, base, cookie;
  const viewport = { width: 1180, height: 820 };
  const page = 'converted/notes.pdf/index.html';

  before(async () => {
    root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'pdf-ink-test-')));
    await fs.writeFile(path.join(root, 'notes.pdf'), boxPdf());
    await fs.writeFile(path.join(root, 'plain.html'), '<body>x</body>');
    await convertDocument(root, 'notes.pdf');
    s = await startServer({ root, port: 0, host: '127.0.0.1', quiet: true });
    base = `http://127.0.0.1:${s.port}`;
    cookie = `pr_token=${s.token}`;
  });
  after(() => s.close());

  const post = (body, headers = { cookie }) => fetch(`${base}/__pr/api/pages/pdf`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, body: JSON.stringify(body) });

  test('page layout matches the paged HTML sizing', () => {
    // 1600×2133 image in an iPad landscape viewport: limited by the height left under the header.
    const l = pageLayout(viewport, 1600, 2133);
    assert.equal(l.y, 60);
    assert.ok(Math.abs(l.scale - 748 / 2133) < 1e-9);
    assert.ok(Math.abs(l.x - (1180 - 1600 * l.scale) / 2) < 1e-9);
    // Never enlarged.
    assert.equal(pageLayout({ width: 3000, height: 3000 }, 800, 600).scale, 1);
  });

  test('draws the ink where it was written on the original page', async () => {
    const { version } = await readContent(root, page);
    const { x, y, scale } = pageLayout(viewport, 1600, Math.round(400 * 1600 / 300));
    const unit = scale * 1600;
    // A red line across (15..45, 20) pt, written on page 1 at this viewport.
    const at = (px, py) => [x + (px / 300) * unit, y + (py / 300) * unit, 0.5];
    const stroke = { id: 's_pdfink001', tool: 'pen', color: '#ff0000', width: (4 / 300) * unit, points: [at(15, 20), at(30, 20), at(45, 20)], createdAt: '2026-10-27T00:00:00Z', state: '#page=1' };
    const meta = { page, contentVersion: version, viewport, device: 'test' };
    const added = await (await fetch(`${base}/__pr/api/reviews/r_pdfink001/ops`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: JSON.stringify({ meta, ops: [{ opId: 'o_pdfink001', type: 'add', stroke }] }) })).json();
    assert.equal(added.changed, 1);

    const res = await post({ page });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get('content-type'), 'application/pdf');
    assert.equal(res.headers.get('x-strokes'), '1');
    assert.match(res.headers.get('content-disposition'), new RegExp(encodeURIComponent('notes (필기).pdf').replace(/[()]/g, '\\$&')));
    const saved = decodeURIComponent(res.headers.get('x-saved'));
    assert.match(saved, /^\.pencil-review\/saved\/.+ notes \(필기\)\.pdf$/);
    const body = Buffer.from(await res.arrayBuffer());
    assert.deepEqual(body, await fs.readFile(path.join(root, saved)));

    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pdf-ink-px-'));
    const out = path.join(dir, 'out.pdf');
    await fs.writeFile(out, body);
    const px = await pixels(out, dir);
    const [r, g, b] = px(30, 20);
    assert.ok(r > 200 && g < 80 && b < 80, `ink at (30, 20) is ${[r, g, b]}`);
    assert.deepEqual(px(30, 30).map((c) => c > 240), [true, true, true], 'no ink below the line');
    const box = px(150, 200);
    assert.ok(box[2] > 200 && box[0] < 50, `original page still drawn: ${box}`);
    // The original is untouched.
    assert.equal(await fs.readFile(path.join(root, 'notes.pdf'), 'latin1'), boxPdf());
  });

  test('refuses pages that are not converted documents, and needs the token', async () => {
    assert.equal((await post({ page: 'plain.html' })).status, 400);
    assert.equal((await post({ page: '../x' })).status, 400);
    assert.equal((await post({ page }, {})).status, 401);
  });
});
