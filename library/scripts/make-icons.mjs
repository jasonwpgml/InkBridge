// Draws the home-screen icons (client/icon-*.png) without image libraries: a blue square with a white ink stroke.
// Run: node library/scripts/make-icons.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const OUT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'client');
const BG = [10, 99, 214];
const INK = [255, 255, 255];

function crc32(buf) {
  return zlib.crc32(buf) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function png(size, rgb) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // RGB
  const raw = Buffer.alloc((size * 3 + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (size * 3 + 1)] = 0;
    rgb.copy(raw, y * (size * 3 + 1) + 1, y * size * 3, (y + 1) * size * 3);
  }
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

function distToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax;
  const dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy || 1)));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

function draw(size) {
  // A handwritten-looking wave across the middle, in unit coordinates.
  const pts = [];
  for (let i = 0; i <= 120; i++) {
    const t = i / 120;
    pts.push([0.2 + 0.6 * t, 0.56 - 0.13 * Math.sin(t * Math.PI * 2.2) * (1 - 0.35 * t) - 0.04 * t]);
  }
  const half = size * 0.045;
  const rgb = Buffer.alloc(size * size * 3);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let d = Infinity;
      for (let i = 1; i < pts.length; i++) {
        d = Math.min(d, distToSegment(x + 0.5, y + 0.5, pts[i - 1][0] * size, pts[i - 1][1] * size, pts[i][0] * size, pts[i][1] * size));
      }
      const a = Math.max(0, Math.min(1, half - d + 0.5));
      const o = (y * size + x) * 3;
      for (let c = 0; c < 3; c++) rgb[o + c] = Math.round(BG[c] * (1 - a) + INK[c] * a);
    }
  }
  return png(size, rgb);
}

for (const size of [180, 192, 512]) {
  fs.writeFileSync(path.join(OUT, `icon-${size}.png`), draw(size));
  console.log(`icon-${size}.png`);
}
