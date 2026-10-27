import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, test } from 'node:test';
import { extractRefs, injectOverlay, readContent } from '../lib/content.mjs';
import { convertDocument, isConvertible } from '../lib/convert.mjs';
import { toRelative } from '../lib/paths.mjs';
import { ReviewStore } from '../lib/store.mjs';
import { startServer } from '../server.mjs';

const stroke = (id, extra = {}) => ({
  id, tool: 'pen', color: '#e5484d', width: 2.5, points: [[10, 20, 0.5], [30, 40, 0.6]], createdAt: '2026-10-26T00:00:00Z', ...extra,
});
const meta = (version = '0123456789abcdef') => ({ page: 'index.html', contentVersion: version, viewport: { width: 1180, height: 820 }, device: 'test' });

async function tempRoot() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'pencil-review-test-'));
  return fs.realpath(dir);
}

describe('paths', () => {
  test('rejects traversal, encoded traversal, NUL and hidden segments', () => {
    assert.equal(toRelative('/a/b.html'), 'a/b.html');
    assert.equal(toRelative('/%ED%95%9C%EA%B8%80.html'), '한글.html');
    for (const bad of ['/../x', '/%2e%2e/x', '/a/%2e%2e/%2e%2e/x', '/.git/config', '/.env', '/.pencil-review/token', '/a/.hidden/b']) {
      assert.throws(() => toRelative(bad), bad);
    }
    assert.throws(() => toRelative('/%E0%A4%A'), /bad encoding/);
    assert.throws(() => toRelative('/a%00b'), /bad path/);
    assert.throws(() => toRelative('/a%5c..%5cb'), /bad path/);
  });
});

describe('content', () => {
  test('extracts local refs and skips remote, data and hidden ones', () => {
    const html = '<link href="css/a.css?v=1"><img src="/img/b.png"><script src="https://x/y.js"></script><a href="#top"></a><img src="data:image/png;base64,x"><a href="../up.html"></a><a href="../../out.html"></a><img src=".secret/x.png">';
    assert.deepEqual(extractRefs(html, 'docs/index.html', 'html'), ['docs/css/a.css', 'img/b.png', 'up.html']);
    assert.deepEqual(extractRefs('a{background:url("../i.png")} @import "b.css";', 'docs/css/a.css', 'css'), ['docs/i.png', 'docs/css/b.css']);
  });

  test('content version changes when a referenced stylesheet changes', async () => {
    const root = await tempRoot();
    await fs.writeFile(path.join(root, 'index.html'), '<link rel="stylesheet" href="s.css"><body>x</body>');
    await fs.writeFile(path.join(root, 's.css'), 'body{color:red}');
    const a = await readContent(root, 'index.html');
    await fs.writeFile(path.join(root, 's.css'), 'body{color:blue}');
    const b = await readContent(root, 'index.html');
    assert.notEqual(a.version, b.version);
    assert.deepEqual([...b.files.keys()].sort(), ['index.html', 's.css']);
  });

  test('injects before the last </body> and escapes attributes', () => {
    const out = injectOverlay('<body><p>&lt;/body&gt;</p></BODY>', { page: 'a"b.html' });
    assert.match(out, /<script src="\/__pr\/overlay.js" defer data-page="a&#34;b.html"><\/script><\/BODY>$/);
    assert.match(injectOverlay('<p>no body', {}), /<p>no body<link/);
  });
});

// A one-page PDF built by hand (no libraries), with correct xref offsets.
function minimalPdf() {
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

describe('convert', () => {
  test('a PDF becomes a paged HTML document with one image per page, reconverted only when it changes', async () => {
    const root = await tempRoot();
    await fs.mkdir(path.join(root, 'docs'));
    await fs.writeFile(path.join(root, 'docs', 'slides.pdf'), minimalPdf());
    assert.equal(isConvertible('docs/slides.pdf'), true);
    assert.equal(isConvertible('converted/docs/slides.pdf'), false);
    const out = await convertDocument(root, 'docs/slides.pdf');
    assert.deepEqual([out.output, out.pages], ['converted/docs/slides.pdf/index.html', 1]);
    const html = await fs.readFile(path.join(root, out.output), 'utf8');
    assert.match(html, /<title>slides\.pdf<\/title>/);
    assert.match(html, /"src":"pages\/001\.png","w":1600,"h":2133/);
    const png = await fs.readFile(path.join(root, 'converted/docs/slides.pdf/pages/001.png'));
    assert.equal(png.subarray(1, 4).toString(), 'PNG');
    assert.equal((await convertDocument(root, 'docs/slides.pdf')).skipped, true);
  });
});

describe('store', () => {
  test('ops are idempotent, erased strokes stay erased, file is rewritten atomically', async () => {
    const root = await tempRoot();
    const store = new ReviewStore(root);
    await store.init();
    const add = { opId: 'o_add000001', type: 'add', stroke: stroke('s_aaaaaa01') };
    const r1 = await store.applyOps('r_review01', meta(), [add]);
    assert.deepEqual([r1.revision, r1.changed, r1.added.map((s) => s.id), r1.removed], [1, 1, ['s_aaaaaa01'], []]);
    // Retried batch: no change, no revision bump.
    const retry = await store.applyOps('r_review01', meta(), [add]);
    assert.deepEqual([retry.revision, retry.changed, retry.added, retry.removed], [1, 0, [], []]);
    const er = await store.applyOps('r_review01', null, [{ opId: 'o_erase0001', type: 'erase', strokeIds: ['s_aaaaaa01'] }]);
    assert.deepEqual([er.revision, er.added, er.removed], [2, [], ['s_aaaaaa01']]);
    // A late add of an erased stroke under a new op id is ignored.
    const late = await store.applyOps('r_review01', null, [{ opId: 'o_late00001', type: 'add', stroke: stroke('s_aaaaaa01') }]);
    assert.equal(late.changed, 0);
    const reloaded = new ReviewStore(root);
    await reloaded.init();
    const r = reloaded.get('r_review01');
    assert.equal(r.strokes.length, 0);
    assert.deepEqual(r.erased, ['s_aaaaaa01']);
    assert.equal(r.revision, 2);
    const leftovers = (await fs.readdir(path.join(root, 'reviews'))).filter((n) => n.endsWith('.tmp'));
    assert.deepEqual(leftovers, []);
  });

  test('keeps the page state a stroke was drawn in', async () => {
    const root = await tempRoot();
    const store = new ReviewStore(root);
    await store.init();
    await store.applyOps('r_review04', meta(), [
      { opId: 'o_state0001', type: 'add', stroke: stroke('s_state0001', { state: '#step=3' }) },
      { opId: 'o_state0002', type: 'add', stroke: stroke('s_state0002') },
    ]);
    assert.deepEqual(store.get('r_review04').strokes.map((s) => s.state), ['#step=3', '']);
    // InkBridge Pad pen types are kept; anything else is refused.
    await store.applyOps('r_review04', null, [{ opId: 'o_kind00001', type: 'add', stroke: stroke('s_kind00001', { kind: 'fountain' }) }]);
    assert.equal(store.get('r_review04').strokes.at(-1).kind, 'fountain');
    await assert.rejects(store.applyOps('r_review04', null, [{ opId: 'o_kind00002', type: 'add', stroke: stroke('s_kind00002', { kind: 'brush' }) }]), /stroke.kind/);
    await assert.rejects(store.applyOps('r_review04', null, [{ opId: 'o_state0003', type: 'add', stroke: stroke('s_state0003', { state: 'x'.repeat(201) }) }]), /stroke.state/);
  });

  test('concurrent batches are serialized without losing strokes', async () => {
    const root = await tempRoot();
    const store = new ReviewStore(root);
    await store.init();
    const jobs = Array.from({ length: 30 }, (_, i) => store.applyOps('r_review02', meta(), [
      { opId: `o_conc${String(i).padStart(4, '0')}`, type: 'add', stroke: stroke(`s_conc${String(i).padStart(4, '0')}`) },
    ]));
    await Promise.all(jobs);
    const reloaded = new ReviewStore(root);
    await reloaded.init();
    assert.equal(reloaded.get('r_review02').strokes.length, 30);
    assert.equal(reloaded.get('r_review02').revision, 30);
  });

  test('rejects invalid input', async () => {
    const root = await tempRoot();
    const store = new ReviewStore(root);
    await store.init();
    const bad = [
      ['r_review03', meta(), [{ opId: 'o_x0000001', type: 'add', stroke: stroke('s_bbbbbb01', { color: 'red' }) }]],
      ['r_review03', meta(), [{ opId: 'o_x0000002', type: 'add', stroke: stroke('s_bbbbbb02', { points: [[1, 2, 5]] }) }]],
      ['r_review03', meta(), [{ opId: 'o_x0000003', type: 'replace' }]],
      ['r_review03', { ...meta(), page: '../x.html' }, [{ opId: 'o_x0000004', type: 'add', stroke: stroke('s_bbbbbb04') }]],
      ['../evil', meta(), []],
    ];
    for (const [id, m, ops] of bad) await assert.rejects(store.applyOps(id, m, ops), /./);
    assert.equal(store.get('r_review03'), null);
  });
});

describe('server', () => {
  let root, s, base, cookie;
  before(async () => {
    root = await tempRoot();
    await fs.writeFile(path.join(root, 'index.html'), '<!doctype html><link rel="stylesheet" href="s.css"><body><p>hello</p></body>');
    await fs.writeFile(path.join(root, 's.css'), 'p{color:red}');
    await fs.mkdir(path.join(root, '.git'));
    await fs.writeFile(path.join(root, '.git', 'config'), 'secret');
    await fs.writeFile(path.join(root, '.env'), 'SECRET=1');
    const outside = await tempRoot();
    await fs.writeFile(path.join(outside, 'secret.txt'), 'OUTSIDE-CONTENT');
    await fs.symlink(path.join(outside, 'secret.txt'), path.join(root, 'link.txt'));
    s = await startServer({ root, port: 0, host: '127.0.0.1', quiet: true });
    base = `http://127.0.0.1:${s.port}`;
    cookie = `pr_token=${s.token}`;
  });
  after(() => s.close());

  const get = (p, headers = { cookie }) => fetch(base + p, { headers, redirect: 'manual' });

  test('requires the token and exchanges ?t= for a cookie', async () => {
    assert.equal((await get('/index.html', {})).status, 401);
    assert.equal((await get('/index.html?t=wrong', {})).status, 401);
    const res = await get(`/index.html?t=${s.token}&x=1`, {});
    assert.equal(res.status, 303);
    assert.equal(res.headers.get('location'), '/index.html?x=1');
    assert.match(res.headers.get('set-cookie'), /^pr_token=.+HttpOnly; SameSite=Lax/);
    assert.equal((await get('/__pr/events', {})).status, 401);
    assert.equal((await fetch(`${base}/__pr/api/reviews`)).status, 401);
  });

  test('serves HTML with the overlay and saves a snapshot', async () => {
    const res = await get('/index.html');
    assert.equal(res.status, 200);
    const html = await res.text();
    const version = html.match(/data-version="([0-9a-f]{16})"/)[1];
    assert.match(html, /data-page="index.html" data-version="[0-9a-f]{16}" data-mode="live"/);
    const manifest = JSON.parse(await fs.readFile(path.join(s.dataDir, 'snapshots', version, 'manifest.json'), 'utf8'));
    assert.deepEqual(manifest.files.sort(), ['index.html', 's.css']);
    // The snapshot keeps the old stylesheet after the live file changes.
    await fs.writeFile(path.join(root, 's.css'), 'p{color:blue}');
    assert.equal(await (await get(`/__pr/snap/${version}/s.css`)).text(), 'p{color:red}');
    assert.equal(await (await get('/s.css')).text(), 'p{color:blue}');
    assert.match(await (await get(`/__pr/snap/${version}/index.html`)).text(), /data-mode="snapshot"/);
  });

  test('the root is a home screen listing pages with their ink', async () => {
    const home = await (await get('/')).text();
    assert.match(home, /<title>InkBridge 서재<\/title>/);
    assert.doesNotMatch(home, /__pr\/overlay\.js/);
    const pages = await (await get('/__pr/api/pages')).json();
    assert.deepEqual(pages.map((p) => p.path), ['index.html']);
    assert.equal(typeof pages[0].strokes, 'number');
    assert.equal(pages[0].kind, 'web');
    // A folder's own index.html is still reachable by name.
    assert.match(await (await get('/index.html')).text(), /hello/);
  });

  test('imports a document into imported/ under a free name; HTML and odd names are refused', async () => {
    const post = (name, body) => fetch(`${base}/__pr/api/import?name=${encodeURIComponent(name)}`, { method: 'POST', headers: { cookie }, body });
    const first = await (await post('노트.pdf', minimalPdf())).json();
    assert.deepEqual(first, { path: 'imported/노트.pdf', page: 'converted/imported/노트.pdf/index.html' });
    assert.equal((await post('노트.pdf', minimalPdf()).then((r) => r.json())).path, 'imported/노트 (2).pdf');
    assert.equal((await post('../x.pdf', minimalPdf()).then((r) => r.json())).path, 'imported/x.pdf');
    for (const bad of ['page.html', 'page.htm', 'run.sh', '.hidden.pdf', '']) assert.equal((await post(bad, 'x')).status, 400, bad);
    assert.equal((await post('empty.pdf', '')).status, 400);
    assert.equal((await fetch(`${base}/__pr/api/import?name=a.pdf`, { method: 'POST', body: 'x' })).status, 401);
    assert.deepEqual((await fs.readdir(path.join(root, 'imported'))).sort(), ['x.pdf', '노트 (2).pdf', '노트.pdf']);
    await fs.rm(path.join(root, 'imported'), { recursive: true });
  });

  test('clearing and saving need one real page, never every review', async () => {
    const post = (p, body) => fetch(`${base}/__pr/api/${p}`, { method: 'POST', headers: { cookie, 'content-type': 'application/json' }, body: JSON.stringify(body) });
    for (const body of [{}, { page: '' }, { page: 7 }, { page: '../x.html' }, { page: '/index.html' }]) {
      assert.equal((await post('pages/clear', body)).status, 400, JSON.stringify(body));
      assert.equal((await post('pages/export', body)).status, 400, JSON.stringify(body));
    }
    // What a crafted ?review=../pages/clear used to reach.
    assert.equal((await post('pages/clear/ops', { meta: {}, ops: [] })).status, 404);
  });

  test('refuses changes sent from another site even with the cookie', async () => {
    const clear = (origin) => fetch(`${base}/__pr/api/pages/clear`, {
      method: 'POST', headers: { cookie, 'content-type': 'application/json', ...(origin ? { origin } : {}) }, body: JSON.stringify({ page: 'none.html' }),
    });
    assert.equal((await clear('https://evil.example')).status, 403);
    assert.equal((await clear('null')).status, 403);
    assert.equal((await clear(base)).status, 200);
    assert.equal((await clear()).status, 200);
  });

  test('web app manifest starts from the token URL; icons need no token', async () => {
    const manifest = await (await get('/__pr/manifest.webmanifest', { cookie, 'sec-fetch-dest': 'manifest' })).json();
    assert.equal(manifest.start_url, `/?t=${s.token}`);
    assert.equal(manifest.display, 'standalone');
    assert.equal((await get('/__pr/manifest.webmanifest', {})).status, 401);
    for (const headers of [{ cookie, 'sec-fetch-dest': 'empty' }, { cookie }]) {
      assert.equal((await (await get('/__pr/manifest.webmanifest', headers)).json()).start_url, '/');
    }
    const icon = await get('/__pr/icon-180.png', {});
    assert.equal(icon.status, 200);
    assert.equal(icon.headers.get('content-type'), 'image/png');
  });

  test('does not serve hidden files, traversal or symlinks out of the root', async () => {
    for (const p of ['/.git/config', '/.env', '/.pencil-review/token', '/%2e%2e/etc/passwd', '/link.txt', '/__pr/snap/0123456789abcdef/../../token']) {
      const res = await get(p);
      assert.ok([400, 403, 404].includes(res.status), `${p} → ${res.status}`);
      assert.doesNotMatch(await res.text(), /secret|SECRET|OUTSIDE-CONTENT/);
    }
  });

  test('ops API saves strokes, broadcasts and exports', async () => {
    const events = await fetch(`${base}/__pr/events`, { headers: { cookie } });
    const reader = events.body.getReader();
    const received = [];
    const reading = (async () => {
      const dec = new TextDecoder();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        received.push(dec.decode(value));
        if (received.join('').includes('event: review')) break;
      }
    })();
    const body = { meta: meta(), ops: [{ opId: 'o_srv000001', type: 'add', stroke: stroke('s_srv00001', { anchors: [{ selector: 'p', text: 'hello', rect: [8, 8, 100, 20] }], context: 'hello' }) }] };
    const post = await fetch(`${base}/__pr/api/reviews/r_server01/ops`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    assert.deepEqual(await post.json(), { revision: 1, changed: 1 });
    await reading;
    await reader.cancel();
    const delta = JSON.parse(received.join('').match(/event: review\ndata: (.*)\n/)[1]);
    assert.deepEqual([delta.id, delta.revision, delta.page, delta.viewport, delta.removed], ['r_server01', 1, 'index.html', { width: 1180, height: 820 }, []]);
    assert.deepEqual(delta.added.map((s) => s.id), ['s_srv00001']);

    const list = await (await get('/__pr/api/reviews?page=index.html&w=1180&h=820')).json();
    assert.equal(list[0].id, 'r_server01');
    const full = await (await get('/__pr/api/reviews/r_server01')).json();
    assert.equal(full.appliedOps, undefined);
    assert.equal(full.strokes[0].context, 'hello');

    const bad = await fetch(`${base}/__pr/api/reviews/r_server01/ops`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: '{' });
    assert.equal(bad.status, 400);

    const exp = await (await fetch(`${base}/__pr/api/reviews/r_server01/export`, { method: 'POST', headers: { cookie } })).json();
    const md = await fs.readFile(path.join(exp.dir, 'REVIEW.md'), 'utf8');
    assert.match(md, /`p` \[8, 8, 100, 20\]: hello/);
    assert.match(await fs.readFile(path.join(exp.dir, 'strokes.svg'), 'utf8'), /<path id="s_srv00001"/);
  });

  test('live points are relayed to viewers without being stored', async () => {
    const events = await fetch(`${base}/__pr/events`, { headers: { cookie } });
    const reader = events.body.getReader();
    const dec = new TextDecoder();
    await reader.read(); // hello
    const body = { clientId: 'c_client0001', meta: meta(), stroke: { id: 's_live00001', tool: 'pen', color: '#e5484d', width: 2.5, state: '#step=2' }, from: 0, points: [[1, 2, 0.5], [3, 4, 0.5]] };
    const post = await fetch(`${base}/__pr/api/reviews/r_live00001/live`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    assert.equal(post.status, 204);
    let text = '';
    while (!text.includes('event: live')) text += dec.decode((await reader.read()).value);
    await reader.cancel();
    const data = JSON.parse(text.match(/event: live\ndata: (.*)\n/)[1]);
    assert.deepEqual([data.review, data.clientId, data.stroke.state, data.from, data.points.length, data.done], ['r_live00001', 'c_client0001', '#step=2', 0, 2, false]);
    assert.equal((await get('/__pr/api/reviews/r_live00001')).status, 404);
    const bad = await fetch(`${base}/__pr/api/reviews/r_live00001/live`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: JSON.stringify({ ...body, points: [[1, 2, 9]] }) });
    assert.equal(bad.status, 400);
  });

  test('notes are saved and cleared per page state or per document', async () => {
    const add = (rid, sid, st) => fetch(`${base}/__pr/api/reviews/${rid}/ops`, {
      method: 'POST', headers: { cookie, 'Content-Type': 'application/json' },
      body: JSON.stringify({ meta: { ...meta(), page: 'deck.html' }, ops: [{ opId: `o_${sid.slice(2)}`, type: 'add', stroke: stroke(sid, { state: st }) }] }),
    });
    await add('r_deck00001', 's_deckp1a01', '#page=1');
    await add('r_deck00001', 's_deckp2a01', '#page=2');
    await add('r_deck00002', 's_deckp1b01', '#page=1');
    const post = (p, b) => fetch(`${base}/__pr/api/pages/${p}`, { method: 'POST', headers: { cookie, 'Content-Type': 'application/json' }, body: JSON.stringify(b) }).then((r) => r.json());
    const pageSave = await post('export', { page: 'deck.html', review: 'r_deck00001', state: '#page=2' });
    assert.equal(pageSave.strokes, 1);
    assert.match(pageSave.dir, /^\.pencil-review\/saved\/deck\.html\/.*-page$/);
    assert.match(await fs.readFile(path.join(root, pageSave.dir, 'r_deck00001', 'REVIEW.md'), 'utf8'), /page state `#page=2`/);
    const docSave = await post('export', { page: 'deck.html' });
    assert.equal(docSave.strokes, 3);
    const cleared = await post('clear', { page: 'deck.html' });
    assert.deepEqual(cleared, { reviews: 2, strokes: 3 });
    assert.equal(s.store.get('r_deck00001').strokes.length + s.store.get('r_deck00002').strokes.length, 0);
  });

  test('the writing device position is relayed and remembered; page turns are relayed', async () => {
    const events = await fetch(`${base}/__pr/events`, { headers: { cookie } });
    const reader = events.body.getReader();
    const dec = new TextDecoder();
    await reader.read(); // hello
    const json = { cookie, 'Content-Type': 'application/json' };
    assert.equal((await fetch(`${base}/__pr/api/presence`, { method: 'POST', headers: json, body: JSON.stringify({ clientId: 'c_ipad00001', review: 'r_where0001', meta: meta(), state: '#step=3' }) })).status, 204);
    assert.equal((await fetch(`${base}/__pr/api/navigate`, { method: 'POST', headers: json, body: JSON.stringify({ clientId: 'c_mac000001', page: 'index.html', state: '#step=4' }) })).status, 204);
    let text = '';
    while (!text.includes('event: navigate')) text += dec.decode((await reader.read()).value);
    await reader.cancel();
    assert.match(text, /event: presence\ndata: \{"clientId":"c_ipad00001","review":"r_where0001"/);
    assert.match(text, /event: navigate\ndata: \{"clientId":"c_mac000001","page":"index.html","state":"#step=4"\}/);
    const last = await (await get('/__pr/api/presence')).json();
    assert.deepEqual([last.review, last.state, last.meta.viewport.width], ['r_where0001', '#step=3', 1180]);
  });

  test('file changes send a reload event, data folder changes do not', async () => {
    const events = await fetch(`${base}/__pr/events`, { headers: { cookie } });
    const reader = events.body.getReader();
    const dec = new TextDecoder();
    let text = '';
    await reader.read(); // hello
    await fs.writeFile(path.join(s.dataDir, 'ignored.json'), '{}');
    await fs.writeFile(path.join(root, 'index.html'), '<body>changed</body>');
    const deadline = Date.now() + 3000;
    // Earlier tests' writes may still arrive first; collect reload events until index.html shows up.
    const reloaded = () => [...text.matchAll(/event: reload\ndata: (.*)\n/g)].flatMap((m) => JSON.parse(m[1]).paths);
    while (!reloaded().includes('index.html') && Date.now() < deadline) {
      const { value } = await reader.read();
      text += dec.decode(value);
    }
    await reader.cancel();
    assert.ok(reloaded().includes('index.html'));
    assert.ok(!reloaded().some((p) => p.includes('.pencil-review')));
  });
});
