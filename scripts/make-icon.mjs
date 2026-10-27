// Writes the shared Liquid Glass app icon (Shared/AppIcon.icon): a frosted glass sheet, a suspension bridge
// sketched with a broad fountain-pen nib, and an Apple Pencil still drawing the last cable.
// Then exports the web home-screen icons (library/client/icon-*.png) with Xcode's ictool.
// Run: node scripts/make-icon.mjs
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const ICON = path.join(ROOT, 'Shared', 'AppIcon.icon');
const ICTOOL = '/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool';
const INK = '#13256b';
const NIB_ANGLE = (32 * Math.PI) / 180;

const f = (n) => Number(n.toFixed(1));
const svg = (body) => `<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n${body}\n</svg>\n`;

// Quadratic Bézier helpers: a point at t, and the curve cut off at t.
const quadAt = ([a, c, b], t) => [0, 1].map((i) => (1 - t) ** 2 * a[i] + 2 * t * (1 - t) * c[i] + t ** 2 * b[i]);
const quadUntil = ([a, c, b], t) => [a, [0, 1].map((i) => (1 - t) * a[i] + t * c[i]), quadAt([a, c, b], t)];

// A broad nib is a flat edge dragged along the path. Stamp it densely, swelling where the pen presses
// and thinning as it lifts, with a slight hand wobble so the lines don't look ruled.
function nibStroke(pointAt, { width, lift = true }) {
  const samples = [];
  let length = 0;
  let prev = pointAt(0);
  for (let i = 0; i <= 400; i++) {
    const p = pointAt(i / 400);
    length += Math.hypot(p[0] - prev[0], p[1] - prev[1]);
    samples.push([p, length]);
    prev = p;
  }
  const stamps = [];
  const deg = f((-NIB_ANGLE * 180) / Math.PI);
  for (let s = 0, i = 0; s <= length; s += 1.6) {
    while (i < samples.length - 1 && samples[i + 1][1] < s) i++;
    const t = s / length;
    const [[x, y]] = samples[i];
    const press = Math.min(1, 0.7 + t * 6) * (lift ? 1 - 0.6 * Math.max(0, (t - 0.8) / 0.2) : 1);
    const wobble = Math.sin(s / 37 + width) * 1.3 + Math.sin(s / 13) * 0.4;
    stamps.push(`<ellipse cx="${f(x + wobble * 0.6)}" cy="${f(y + wobble)}" rx="${f((width * press) / 2)}" ry="1.6" transform="rotate(${deg} ${f(x + wobble * 0.6)} ${f(y + wobble)})"/>`);
  }
  return stamps.join('');
}

const line = (a, b) => (t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const quad = (curve) => (t) => quadAt(curve, t);
const wave = (x, y, humps, span = 44) => (t) => [x + t * humps * span, y - Math.sin(t * humps * Math.PI) * 7];

// Bridge layout, in the 1024pt icon grid.
const deckY = 640;
const towers = [372, 652];
const towerTop = 372;
const mainCable = [[towers[0], towerTop + 10], [(towers[0] + towers[1]) / 2, 744], [towers[1], towerTop + 10]];
const leftCable = [[towers[0], towerTop + 10], [300, 590], [186, deckY - 4]];
const rightCable = [[towers[1], towerTop + 10], [724, 590], [838, deckY - 4]];
const drawnTo = 0.6;
const tip = quadAt(rightCable, drawnTo);

function cableYAt(curve, x) {
  let lo = 0;
  let hi = 1;
  const rising = curve[2][0] > curve[0][0];
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    if (quadAt(curve, mid)[0] < x === rising) lo = mid;
    else hi = mid;
  }
  return quadAt(curve, lo)[1];
}

function inkLayer() {
  const strokes = [
    [line([170, deckY + 2], [852, deckY - 3]), { width: 24 }],
    [line([towers[0], towerTop], [towers[0] - 2, 726]), { width: 26 }],
    [line([towers[1], towerTop], [towers[1] + 1, 726]), { width: 26 }],
    [quad(mainCable), { width: 18 }],
    [quad(leftCable), { width: 18 }],
    [quad(quadUntil(rightCable, drawnTo)), { width: 18, lift: false }],
  ];
  for (let x = towers[0] + 35; x < towers[1] - 20; x += 35) strokes.push([line([x, cableYAt(mainCable, x) + 3], [x, deckY]), { width: 8 }]);
  for (let x = towers[0] - 42; x > 214; x -= 42) strokes.push([line([x, cableYAt(leftCable, x) + 3], [x, deckY]), { width: 8 }]);
  for (let x = towers[1] + 42; x < tip[0] - 6; x += 42) strokes.push([line([x, cableYAt(rightCable, x) + 3], [x, deckY]), { width: 8 }]);
  strokes.push([wave(232, 712, 3), { width: 11 }], [wave(450, 748, 4), { width: 11 }], [wave(722, 712, 2, 40), { width: 11 }]);
  return svg(
    [
      `<g fill="${INK}">`,
      ...strokes.map(([pointAt, opts]) => nibStroke(pointAt, opts)),
      // Ink pools where the nib set down on each tower, and a wet bead under the pencil tip.
      `<ellipse cx="${towers[0]}" cy="${towerTop - 2}" rx="12" ry="9"/>`,
      `<ellipse cx="${towers[1]}" cy="${towerTop - 2}" rx="12" ry="9"/>`,
      `<circle cx="${f(tip[0])}" cy="${f(tip[1])}" r="9"/>`,
      '</g>',
    ].join('\n'),
  );
}

// Soft colored light behind the glass sheet, so its frosting has something to blur.
function glowLayer() {
  return svg(
    [
      '<defs>',
      '<radialGradient id="a" cx="250" cy="230" r="430" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#8ff3ff"/><stop offset="1" stop-color="#8ff3ff" stop-opacity="0"/></radialGradient>',
      '<radialGradient id="b" cx="860" cy="880" r="470" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#b48cff"/><stop offset="1" stop-color="#b48cff" stop-opacity="0"/></radialGradient>',
      '</defs>',
      '<rect width="1024" height="1024" fill="url(#a)"/>',
      '<rect width="1024" height="1024" fill="url(#b)" opacity="0.85"/>',
    ].join('\n'),
  );
}

function sheetLayer() {
  return svg('<rect width="1024" height="1024" fill="#ffffff"/>');
}

// Apple Pencil drawn along +x from its tip at the origin, then turned so it leans up and to the right.
function pencilLayer() {
  const angle = -64;
  const r = 34;
  const nibEnd = 26;
  const coneEnd = 132;
  const end = 420;
  return svg(
    [
      '<defs>',
      `<linearGradient id="body" gradientUnits="userSpaceOnUse" x1="0" y1="${-r}" x2="0" y2="${r}">`,
      '<stop offset="0" stop-color="#d9dee6"/><stop offset="0.22" stop-color="#ffffff"/>',
      '<stop offset="0.62" stop-color="#f1f3f7"/><stop offset="1" stop-color="#a9b2c2"/>',
      '</linearGradient>',
      `<linearGradient id="nib" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="${coneEnd}" y2="0">`,
      '<stop offset="0" stop-color="#8f99ab"/><stop offset="0.22" stop-color="#c9d0db"/><stop offset="0.3" stop-color="#eef1f5"/>',
      '<stop offset="1" stop-color="#ffffff"/>',
      '</linearGradient>',
      '</defs>',
      `<g transform="translate(${f(tip[0])},${f(tip[1])}) rotate(${angle})">`,
      `<path d="M${coneEnd},${-r} L${end - 14},${-r} Q${end},${-r} ${end},${-r + 14} L${end},${r - 14} Q${end},${r} ${end - 14},${r} L${coneEnd},${r} Z" fill="url(#body)"/>`,
      `<path d="M2,-2.5 Q0,0 2,2.5 L${nibEnd},6 L${coneEnd},${r} L${coneEnd},${-r} L${nibEnd},-6 Z" fill="url(#nib)"/>`,
      // The flat charging side catches the light as a thin bright band.
      `<rect x="${coneEnd + 18}" y="${-r + 5}" width="${end - coneEnd - 40}" height="5" rx="2.5" fill="#ffffff" opacity="0.9"/>`,
      '</g>',
    ].join('\n'),
  );
}

const iconJson = {
  fill: {
    'linear-gradient': ['display-p3:0.20000,0.56000,1.00000,1.00000', 'display-p3:0.03000,0.18000,0.58000,1.00000'],
    orientation: { start: { x: 0.5, y: 0 }, stop: { x: 0.5, y: 1 } },
  },
  groups: [
    {
      name: 'Pencil',
      layers: [{ name: 'pencil', 'image-name': 'pencil.svg', glass: true }],
      shadow: { kind: 'neutral', opacity: 0.55 },
      specular: true,
      translucency: { enabled: true, value: 0.45 },
    },
    {
      name: 'Ink',
      layers: [
        {
          name: 'bridge',
          'image-name': 'bridge.svg',
          // Glass ink: the strokes pick up rim highlights, as if etched into the sheet.
          glass: true,
          'fill-specializations': [{ appearance: 'dark', value: { solid: 'display-p3:0.80000,0.88000,1.00000,1.00000' } }],
        },
      ],
      shadow: { kind: 'neutral', opacity: 0.4 },
      specular: true,
      translucency: { enabled: true, value: 0.2 },
    },
    {
      name: 'Glass sheet',
      layers: [
        {
          name: 'sheet',
          'image-name': 'sheet.svg',
          glass: true,
          opacity: 0.85,
          // In dark mode the sheet turns to smoked glass, close to black, so the light ink carries the icon.
          'fill-specializations': [{ appearance: 'dark', value: { solid: 'display-p3:0.07000,0.08000,0.10000,1.00000' } }],
        },
      ],
      shadow: { kind: 'neutral', opacity: 0.5 },
      specular: true,
      translucency: { enabled: true, value: 0.5 },
    },
    {
      name: 'Glow',
      layers: [{ name: 'glow', 'image-name': 'glow.svg', glass: false, 'opacity-specializations': [{ appearance: 'dark', value: 0.3 }] }],
      shadow: { kind: 'none', opacity: 0.5 },
      translucency: { enabled: false, value: 0.5 },
    },
  ],
  'supported-platforms': { squares: 'shared' },
};

fs.mkdirSync(path.join(ICON, 'Assets'), { recursive: true });
fs.writeFileSync(path.join(ICON, 'Assets', 'glow.svg'), glowLayer());
fs.writeFileSync(path.join(ICON, 'Assets', 'sheet.svg'), sheetLayer());
fs.writeFileSync(path.join(ICON, 'Assets', 'bridge.svg'), inkLayer());
fs.writeFileSync(path.join(ICON, 'Assets', 'pencil.svg'), pencilLayer());
fs.writeFileSync(path.join(ICON, 'icon.json'), `${JSON.stringify(iconJson, null, 2)}\n`);
console.log(path.relative(ROOT, ICON));

const exportPNG = (out, size, platform = 'iOS', rendition = 'Default') =>
  execFileSync(ICTOOL, [ICON, '--export-image', '--output-file', out, '--platform', platform, '--rendition', rendition, '--width', String(size), '--height', String(size), '--scale', '1']);

const preview = process.argv[2];
if (preview) {
  fs.mkdirSync(preview, { recursive: true });
  for (const [platform, rendition] of [['iOS', 'Default'], ['macOS', 'Default'], ['iOS', 'Dark'], ['iOS', 'ClearLight']]) {
    exportPNG(path.join(preview, `${platform}-${rendition}.png`), 1024, platform, rendition);
  }
  console.log(`previews: ${preview}`);
} else {
  for (const size of [180, 192, 512]) {
    const out = path.join(ROOT, 'library', 'client', `icon-${size}.png`);
    exportPNG(out, size);
    // iOS fills a touch icon's transparent corners with black before masking it, so back it with the icon's own gradient.
    if (size === 180) execFileSync('xcrun', ['swift', path.join(ROOT, 'scripts', 'flatten-icon.swift'), out]);
    console.log(path.relative(ROOT, out));
  }
}
