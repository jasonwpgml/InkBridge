// 서재 (library) overlay: injected into served HTML. See ../DESIGN.md for the decisions behind it.
(() => {
  if (window.__pencilReview) return;
  const script = document.currentScript;
  const PAGE = script.dataset.page;
  const VERSION = script.dataset.version;
  const MODE = script.dataset.mode; // 'live' or 'snapshot'
  // Converted PDFs, slides and Word files can be written back out as a PDF with the ink on it.
  const PAGED = /^converted\/.+\/index\.html$/.test(PAGE ?? '');
  const params = new URLSearchParams(location.search);
  // Only a well-formed review id; anything else in ?review= could steer the API paths built from it.
  const FIXED_REVIEW = /^r_[A-Za-z0-9_-]{6,40}$/.test(params.get('review') ?? '') ? params.get('review') : null;
  const EXPORT = params.has('export');
  // The toolbar is for the device that writes; Macs without touch only view unless ?tools is given (e.g. Sidecar).
  const SHOW_TOOLS = params.has('tools') || (navigator.maxTouchPoints > 0 && !(window.parent !== window && params.get('review')));
  // Inside InkBridge Pad the app draws the toolbar and the squeeze palette; the page only inks and reports its state.
  const NATIVE = window.webkit?.messageHandlers?.pencilReview ?? null;
  const API = '/__pr/api';
  const COLORS = ['#e5484d', '#1f6feb', '#1c1c1e', '#30a46c', '#ffd60a'];
  const WIDTHS = { pen: [1.5, 3, 5], highlighter: [10, 16, 24] };
  const ERASE_RADIUS = 10;
  const TAP_MAX_MS = 350;
  const TAP_MAX_MOVE = 6;
  // A short pen tap on these acts as a press instead of a dot of ink.
  const TAPPABLE = 'a[href], button, summary, label, select, textarea, input, [role="button"], [role="tab"], [onclick]';
  // The pen drags these natively instead of drawing.
  const PASS_THROUGH = 'input[type="range"]';
  const RELOAD_IDLE_MS = 800;
  const CLICK_GUARD_MS = 500;
  const LIVE_INTERVAL_MS = 33;     // in-progress points are sent at most ~30 times a second
  const LIVE_STALE_MS = 5000;      // a live preview with no update for this long is dropped

  const state = {
    review: null,          // { id, meta, revision }
    serverStrokes: [],
    strokes: [],           // what is drawn: server strokes plus pending local ops
    tool: 'pen',
    prefs: loadPrefs(),
    hidden: false,
    mouseDraw: false,
    active: null,          // in-progress stroke or erase gesture
    lastInput: 0,
    lastPenEnd: -Infinity,
    pending: 0,
    idbWrites: 0,
    online: false,
    authLost: false,
    rejected: 0,
    undo: [],
    redo: [],
    reloadWanted: false,
    selfReload: false,
    passClick: false,
  };
  window.__pencilReview = state;
  const CLIENT_ID = uid('c_');
  const live = new Map(); // strokeId → { stroke, timer } previews from other devices
  state.livePreviews = live;

  // ---------- small helpers ----------

  function uid(prefix) {
    const bytes = crypto.getRandomValues(new Uint8Array(12));
    return prefix + btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function loadPrefs() {
    const fallback = { pen: { color: COLORS[0], size: 0 }, highlighter: { color: COLORS[4], size: 0 } };
    try {
      return { ...fallback, ...JSON.parse(localStorage.getItem('pr:prefs') || '{}') };
    } catch {
      return fallback;
    }
  }

  function savePrefs() {
    try {
      localStorage.setItem('pr:prefs', JSON.stringify(state.prefs));
    } catch {
      // Preferences are a convenience only.
    }
  }

  // Large-viewport height: Safari's innerHeight changes as the toolbar collapses, 100lvh does not.
  function measureViewport() {
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;top:0;left:0;width:1px;height:100vh;visibility:hidden;pointer-events:none';
    if (CSS.supports('height', '100lvh')) probe.style.height = '100lvh';
    document.documentElement.appendChild(probe);
    const height = Math.round(probe.getBoundingClientRect().height);
    probe.remove();
    return { width: document.documentElement.clientWidth, height };
  }

  // Dynamic pages (steps, tabs) keep their state in the URL hash; ink belongs to the state it was drawn in.
  const pageState = () => location.hash.slice(0, 200);
  const isVisible = (s) => (s.state ?? '') === pageState();
  const visibleStrokes = () => state.strokes.filter(isVisible);

  const sameViewport = (a, b) => a && b && a.width === b.width && a.height === b.height;
  const reviewKey = (vp) => `pr:review:${PAGE}|${VERSION}|${vp.width}x${vp.height}`;

  // Paged documents (converted PDF, slides, Word) keep ink in page-image pixels instead of screen pixels, so every
  // screen size shares one review and the Mac and the iPad see the same notes. Such a review's viewport is
  // PAGE_SPACE (lib/pdf-ink.mjs reads it the same way); reviews written before keep their screen coordinates.
  const PAGE_IMG = PAGED ? document.getElementById('page') : null;
  const PAGE_SPACE = { width: 1600, height: 1600 };
  const reviewViewport = () => (PAGE_IMG ? PAGE_SPACE : viewport);
  const inPageSpace = () => !!PAGE_IMG && sameViewport(state.review?.meta.viewport ?? PAGE_SPACE, PAGE_SPACE);

  // Where ink unit (0, 0) sits in the document and how many document px one unit spans.
  function inkFrame() {
    if (!inPageSpace()) return { x: 0, y: 0, k: 1 };
    const r = PAGE_IMG.getBoundingClientRect();
    return { x: r.left + window.scrollX, y: r.top + window.scrollY, k: r.width / Number(PAGE_IMG.getAttribute('width')) || 1 };
  }

  function bboxOf(s) {
    if (s._bbox) return s._bbox;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const [x, y] of s.points) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    const pad = s.width;
    Object.defineProperty(s, '_bbox', { value: [minX - pad, minY - pad, maxX + pad, maxY + pad], enumerable: false });
    return s._bbox;
  }

  function cleanStroke(s) {
    const { id, tool, color, width, kind, points, anchors, context, createdAt, state: pageHash } = s;
    return { id, tool, color, width, kind, points, anchors, context, createdAt, state: pageHash ?? '' };
  }

  // ---------- IndexedDB queue: every op is stored here before it is sent ----------

  const memoryQueue = new Map();
  let dbPromise = null;

  function openDb() {
    if (!dbPromise) {
      dbPromise = new Promise((resolve) => {
        let req;
        try {
          req = indexedDB.open('pencil-review', 1);
        } catch {
          return resolve(null);
        }
        req.onupgradeneeded = () => {
          req.result.createObjectStore('ops', { keyPath: 'opId' });
          req.result.createObjectStore('rejected', { keyPath: 'opId' });
        };
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => resolve(null);
      });
    }
    return dbPromise;
  }

  function tx(db, store, mode, fn) {
    return new Promise((resolve, reject) => {
      const t = db.transaction(store, mode);
      const result = fn(t.objectStore(store));
      t.oncomplete = () => resolve(result && 'result' in result ? result.result : undefined);
      t.onerror = () => reject(t.error);
      t.onabort = () => reject(t.error);
    });
  }

  async function queuePut(record) {
    state.idbWrites++;
    try {
      const db = await openDb();
      if (db) await tx(db, 'ops', 'readwrite', (s) => s.put(record));
      else memoryQueue.set(record.opId, record);
    } finally {
      state.idbWrites--;
    }
  }

  async function queueAll() {
    const db = await openDb();
    const all = db ? await tx(db, 'ops', 'readonly', (s) => s.getAll()) : [...memoryQueue.values()];
    return all.sort((a, b) => a.seq - b.seq);
  }

  async function queueRemove(ids, rejectedRecords) {
    const db = await openDb();
    if (!db) {
      ids.forEach((id) => memoryQueue.delete(id));
      return;
    }
    await tx(db, 'ops', 'readwrite', (s) => ids.forEach((id) => s.delete(id)));
    if (rejectedRecords) await tx(db, 'rejected', 'readwrite', (s) => rejectedRecords.forEach((r) => s.put(r)));
  }

  let seq = 0;
  const unqueued = new Map(); // ops between commit and the finished IndexedDB write
  async function enqueue(op) {
    const review = ensureReview();
    const record = { opId: op.opId, reviewId: review.id, meta: review.meta, op, seq: Date.now() * 1000 + (seq++ % 1000) };
    unqueued.set(op.opId, record);
    try {
      await queuePut(record);
    } finally {
      unqueued.delete(op.opId);
    }
    await refreshPending();
    flush();
  }

  async function refreshPending() {
    state.pending = (await queueAll()).length;
    renderStatus();
  }

  let flushing = false;
  let retryDelay = 1000;
  let retryTimer = null;

  async function flush() {
    if (flushing || state.authLost) return;
    flushing = true;
    clearTimeout(retryTimer);
    try {
      for (;;) {
        const all = await queueAll();
        if (!all.length) break;
        const batch = all.filter((r) => r.reviewId === all[0].reviewId).slice(0, 100);
        const res = await fetch(`${API}/reviews/${encodeURIComponent(batch[0].reviewId)}/ops`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ meta: batch[0].meta, ops: batch.map((r) => r.op) }),
        });
        if (res.status === 401) {
          state.authLost = true;
          break;
        }
        if (res.status === 400) {
          // Kept in a separate store instead of being dropped, so nothing written is lost silently.
          await queueRemove(batch.map((r) => r.opId), batch);
          state.rejected += batch.length;
          continue;
        }
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        await queueRemove(batch.map((r) => r.opId));
        // The revision is not taken from this response: the 'review' event carries the same change,
        // and applying it there keeps serverStrokes and revision in step.
      }
      state.online = true;
      retryDelay = 1000;
    } catch {
      state.online = false;
      retryTimer = setTimeout(flush, retryDelay);
      retryDelay = Math.min(retryDelay * 2, 15000);
    } finally {
      flushing = false;
      await refreshPending();
    }
  }

  // ---------- review selection and loading ----------

  let viewport = measureViewport();

  function ensureReview() {
    if (!state.review) {
      state.review = { id: uid('r_'), revision: 0, meta: { page: PAGE, contentVersion: VERSION, viewport: reviewViewport(), device: navigator.userAgent.slice(0, 200) } };
    }
    try {
      localStorage.setItem(reviewKey(state.review.meta.viewport), state.review.id);
    } catch {
      // Without storage the server lookup in selectReview still finds the review.
    }
    return state.review;
  }

  async function selectReview() {
    if (FIXED_REVIEW) {
      const r = await fetchReview(FIXED_REVIEW);
      // A review the iPad has opened but not written in yet is not on the server; its first delta starts it.
      state.review = r ? { id: r.id, revision: r.revision, meta: { page: r.page, contentVersion: r.contentVersion, viewport: r.viewport, device: r.device } }
        : { id: FIXED_REVIEW, revision: 0, meta: { page: PAGE, contentVersion: VERSION, viewport: reviewViewport(), device: '' } };
      return applyServer(r);
    }
    const vp = reviewViewport();
    let id = null;
    try {
      id = localStorage.getItem(reviewKey(vp));
    } catch {
      // Fall through to the server lookup.
    }
    if (!id) {
      try {
        const res = await fetch(`${API}/reviews?page=${encodeURIComponent(PAGE)}&version=${VERSION}&w=${vp.width}&h=${vp.height}`);
        if (res.ok) id = (await res.json())[0]?.id ?? null;
      } catch {
        // Offline: a new review is created locally on the first stroke.
      }
    }
    state.review = id ? { id, revision: 0, meta: { page: PAGE, contentVersion: VERSION, viewport: vp, device: navigator.userAgent.slice(0, 200) } } : null;
    await applyServer(id ? await fetchReview(id) : null);
  }

  async function fetchReview(id) {
    try {
      const res = await fetch(`${API}/reviews/${encodeURIComponent(id)}`);
      if (res.status === 401) state.authLost = true;
      return res.ok ? await res.json() : null;
    } catch {
      return null;
    }
  }

  async function applyServer(r) {
    if (r && state.review && r.id === state.review.id) {
      state.serverStrokes = r.strokes;
      state.review.revision = r.revision;
    } else {
      state.serverStrokes = [];
    }
    await rebuild();
  }

  // Server strokes with this review's unsent ops replayed on top.
  async function rebuild() {
    const queued = state.review ? await queueAll() : [];
    const strokes = new Map(state.serverStrokes.map((s) => [s.id, s]));
    if (state.review) {
      const records = new Map(queued.map((r) => [r.opId, r]));
      for (const r of unqueued.values()) records.set(r.opId, r);
      for (const r of [...records.values()].sort((a, b) => a.seq - b.seq)) {
        if (r.reviewId !== state.review.id) continue;
        if (r.op.type === 'add') strokes.set(r.op.stroke.id, r.op.stroke);
        else r.op.strokeIds.forEach((id) => strokes.delete(id));
      }
    }
    state.strokes = [...strokes.values()];
    redraw();
    renderStatus();
  }

  async function refreshFromServer() {
    if (state.review) await applyServer(await fetchReview(state.review.id));
  }

  // ---------- canvas band: only the area around the visible viewport has pixels ----------

  const canvas = document.createElement('canvas');
  canvas.id = '__pr-canvas';
  const ctx = canvas.getContext('2d');
  const band = { top: 0, height: 0, width: 0, dpr: 1, offsetY: 0 };

  function visibleRect() {
    const vv = window.visualViewport;
    return vv ? { top: vv.pageTop, height: vv.height } : { top: window.scrollY, height: window.innerHeight };
  }

  function layoutBand(force) {
    const view = visibleRect();
    const width = document.documentElement.clientWidth;
    const covered = view.top >= band.top && view.top + view.height <= band.top + band.height;
    if (!force && covered && width === band.width) return;
    canvas.style.height = '0px';
    const docHeight = Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
    const margin = view.height * 0.5;
    const top = Math.max(0, Math.floor(view.top - margin));
    const height = Math.max(1, Math.min(Math.ceil(view.height * 2), docHeight - top));
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    Object.assign(band, { top, height, width, dpr });
    canvas.width = Math.round(width * dpr);
    canvas.height = Math.round(height * dpr);
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;
    canvas.style.top = `${top - band.offsetY}px`;
    // A positioned <html> shifts absolute children; measure once and compensate.
    const actual = canvas.getBoundingClientRect().top + window.scrollY;
    if (Math.abs(actual - top) > 0.5) {
      band.offsetY += actual - top;
      canvas.style.top = `${top - band.offsetY}px`;
    }
    redraw();
  }

  function redraw() {
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (state.hidden) return;
    const f = setInkTransform();
    const bottom = band.top + band.height;
    for (const s of visibleStrokes()) {
      const b = bboxOf(s);
      if (b[3] * f.k + f.y >= band.top && b[1] * f.k + f.y <= bottom) drawStroke(s, 0);
    }
    for (const { stroke } of live.values()) {
      if (isVisible(stroke) && stroke.points.length) drawStroke(stroke, 0);
    }
    if (state.active?.stroke) drawStroke(state.active.stroke, 0);
  }

  function setInkTransform() {
    const f = inkFrame();
    ctx.setTransform(band.dpr * f.k, 0, 0, band.dpr * f.k, band.dpr * f.x, band.dpr * (f.y - band.top));
    return f;
  }

  // Pen kinds follow PencilKit's look: gel varies with pressure, ballpoint is even, fountain is a 45° broad nib.
  function penWidth(s, a, b) {
    const pressure = (a[2] + b[2]) / 2;
    if (s.kind === 'ballpoint') return s.width * 0.85;
    if (s.kind === 'fountain') {
      const angle = Math.atan2(b[1] - a[1], b[0] - a[0]);
      return s.width * (0.3 + 1.2 * Math.abs(Math.sin(angle - Math.PI / 4))) * (0.6 + 0.8 * pressure);
    }
    return s.width * (0.5 + pressure);
  }

  function drawStroke(s, from) {
    const pts = s.points;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = s.color;
    if (s.tool === 'highlighter') {
      ctx.globalAlpha = 0.35;
      ctx.lineWidth = s.width;
      const start = Math.max(0, from - 1);
      ctx.beginPath();
      ctx.moveTo(pts[start][0], pts[start][1]);
      for (let i = start + 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
      if (pts.length === 1) ctx.lineTo(pts[0][0] + 0.01, pts[0][1]);
      ctx.stroke();
      ctx.globalAlpha = 1;
      return;
    }
    if (pts.length === 1) {
      ctx.fillStyle = s.color;
      ctx.beginPath();
      ctx.arc(pts[0][0], pts[0][1], (s.width * (0.5 + pts[0][2])) / 2, 0, Math.PI * 2);
      ctx.fill();
      return;
    }
    // Quadratic segments through midpoints, width from pressure.
    for (let i = Math.max(1, from); i < pts.length; i++) {
      const p0 = pts[i - 2] ?? pts[i - 1];
      const p1 = pts[i - 1];
      const p2 = pts[i];
      ctx.lineWidth = penWidth(s, p1, p2);
      ctx.beginPath();
      ctx.moveTo((p0[0] + p1[0]) / 2, (p0[1] + p1[1]) / 2);
      ctx.quadraticCurveTo(p1[0], p1[1], (p1[0] + p2[0]) / 2, (p1[1] + p2[1]) / 2);
      ctx.stroke();
    }
    if (from === 0) {
      const a = pts[pts.length - 2];
      const b = pts[pts.length - 1];
      ctx.beginPath();
      ctx.moveTo((a[0] + b[0]) / 2, (a[1] + b[1]) / 2);
      ctx.lineTo(b[0], b[1]);
      ctx.stroke();
    }
  }

  function drawIncrement(s, from) {
    if (state.hidden) return;
    setInkTransform();
    drawStroke(s, from);
  }

  // ---------- DOM context captured while drawing (for the AI export) ----------

  function selectorOf(el) {
    const parts = [];
    for (let node = el; node && node.nodeType === 1 && parts.length < 5; node = node.parentElement) {
      if (node.id) {
        parts.unshift(`#${CSS.escape(node.id)}`);
        break;
      }
      let part = node.localName;
      const parent = node.parentElement;
      if (parent) {
        const same = [...parent.children].filter((c) => c.localName === node.localName);
        if (same.length > 1) part += `:nth-of-type(${same.indexOf(node) + 1})`;
      }
      parts.unshift(part);
      if (node.localName === 'body') break;
    }
    return parts.join(' > ');
  }

  function captureAnchors(s) {
    // A page image has no elements or text under the ink to record.
    if (inPageSpace()) return { anchors: [], context: '' };
    const [x0, y0, x1, y1] = bboxOf(s);
    const samples = [[(x0 + x1) / 2, (y0 + y1) / 2], [x0, y0], [x1, y0], [x0, y1], [x1, y1], s.points[0]];
    const seen = new Set();
    const anchors = [];
    for (const [x, y] of samples) {
      const cx = x - window.scrollX;
      const cy = y - window.scrollY;
      if (cx < 0 || cy < 0 || cx > window.innerWidth || cy > window.innerHeight) continue;
      const el = document.elementFromPoint(cx, cy);
      if (!el || seen.has(el) || el === document.documentElement || el === document.body || el.closest('#__pr-bar')) continue;
      seen.add(el);
      const r = el.getBoundingClientRect();
      const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 200);
      anchors.push({ selector: selectorOf(el).slice(0, 400), text, rect: [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height].map((v) => Math.round(v)) });
      if (anchors.length >= 5) break;
    }
    let context = '';
    const cx = (x0 + x1) / 2 - window.scrollX;
    const cy = (y0 + y1) / 2 - window.scrollY;
    const range = document.caretRangeFromPoint?.(cx, cy);
    const node = range?.startContainer;
    if (node?.nodeType === 3) {
      const t = node.data;
      context = t.slice(Math.max(0, range.startOffset - 80), range.startOffset + 80).replace(/\s+/g, ' ').trim();
    }
    return { anchors, context: context.slice(0, 500) };
  }

  // ---------- input ----------

  const inBar = (e) => e.target instanceof Element && e.target.closest('#__pr-bar');

  function canDraw() {
    if (EXPORT || state.hidden) return false;
    if (FIXED_REVIEW) return !!state.review && sameViewport(reviewViewport(), state.review.meta.viewport);
    return true;
  }

  const passesThrough = (e) => e.target instanceof Element && e.target.closest(PASS_THROUGH);

  function wantsInk(e) {
    if (!canDraw() || inBar(e) || passesThrough(e)) return false;
    if (e.pointerType === 'pen') return true;
    if (e.pointerType === 'touch' && state.native?.finger) return true;
    return state.mouseDraw && e.pointerType === 'mouse' && e.button === 0;
  }

  function pointOf(e) {
    // Document CSS px (clientX + scrollX, i.e. pageX); no visualViewport scale correction (see DESIGN.md 4-c).
    // Synthetic events report pageX without the scroll offset, so it is computed here.
    const pressure = e.pointerType === 'pen' ? Math.max(0.05, Math.min(1, e.pressure || 0.5)) : 0.5;
    const f = inkFrame();
    const x = (e.clientX + window.scrollX - f.x) / f.k;
    const y = (e.clientY + window.scrollY - f.y) / f.k;
    return [Math.round(x * 10) / 10, Math.round(y * 10) / 10, Math.round(pressure * 1000) / 1000];
  }

  function swallow(e) {
    if (e.cancelable) e.preventDefault();
    e.stopPropagation();
    e.stopImmediatePropagation();
  }

  function onPointerDown(e) {
    if (state.active || !wantsInk(e)) return;
    swallow(e);
    state.lastInput = performance.now();
    if (state.tool === 'eraser') {
      state.active = { pointerId: e.pointerId, erase: new Map() };
      eraseAt(pointOf(e));
      return;
    }
    const pref = state.prefs[state.tool];
    const ink = state.native ?? { color: pref.color, width: WIDTHS[state.tool][pref.size] ?? WIDTHS[state.tool][0] };
    const tappable = e.target instanceof Element ? e.target.closest(TAPPABLE) : null;
    state.active = {
      pointerId: e.pointerId,
      tap: tappable && !tappable.closest('#__pr-bar') ? { target: tappable, at: performance.now() } : null,
      stroke: {
        id: uid('s_'), tool: state.tool, color: ink.color, width: Math.round((ink.width / inkFrame().k) * 100) / 100, kind: state.tool === 'pen' ? ink.kind : undefined,
        points: [pointOf(e)], createdAt: new Date().toISOString(), state: pageState(),
      },
    };
    try {
      e.target.setPointerCapture?.(e.pointerId);
    } catch {
      // Capture is best effort; window listeners still receive the events.
    }
  }

  function onPointerMove(e) {
    const a = state.active;
    if (!a || e.pointerId !== a.pointerId) return;
    swallow(e);
    state.lastInput = performance.now();
    const events = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
    const list = events.length ? events : [e];
    if (a.erase) {
      list.forEach((ev) => eraseAt(pointOf(ev)));
      return;
    }
    const pts = a.stroke.points;
    const from = pts.length;
    for (const ev of list) {
      const p = pointOf(ev);
      const last = pts[pts.length - 1];
      if (Math.abs(p[0] - last[0]) + Math.abs(p[1] - last[1]) >= 0.5) pts.push(p);
    }
    if (pts.length > from) {
      sendLive(a);
      delete a.stroke._bbox;
      const f = inkFrame();
      const y = pts[pts.length - 1][1] * f.k + f.y;
      if (y < band.top || y > band.top + band.height) layoutBand(true);
      else drawIncrement(a.stroke, from);
    }
  }

  function onPointerEnd(e) {
    const a = state.active;
    if (!a || e.pointerId !== a.pointerId) return;
    swallow(e);
    state.active = null;
    state.lastInput = performance.now();
    state.lastPenEnd = performance.now();
    if (a.erase) {
      if (a.erase.size) commitErase([...a.erase.values()]);
      return;
    }
    const s = a.stroke;
    delete s._bbox;
    if (a.tap && isTap(s, a.tap.at)) {
      finishLive(a, 'cancel');
      redraw();
      pressTarget(a.tap.target);
      return;
    }
    finishLive(a, 'done');
    Object.assign(s, captureAnchors(s));
    commitAdd(s);
  }

  function isTap(s, startedAt) {
    if (performance.now() - startedAt > TAP_MAX_MS) return false;
    const [x0, y0] = s.points[0];
    const max = TAP_MAX_MOVE / inkFrame().k;
    return s.points.every(([x, y]) => Math.abs(x - x0) <= max && Math.abs(y - y0) <= max);
  }

  // Touch defaults were cancelled for the pen, so the press is replayed here.
  function pressTarget(target) {
    if (target.matches('input:not([type="checkbox"]):not([type="radio"]):not([type="button"]):not([type="submit"]), select, textarea')) {
      target.focus();
      return;
    }
    state.passClick = true;
    try {
      target.click();
    } finally {
      state.passClick = false;
    }
  }

  function distToSegment(p, a, b) {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = dx * dx + dy * dy;
    const t = len ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len)) : 0;
    return Math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
  }

  function eraseAt(p) {
    let hit = false;
    const radius = ERASE_RADIUS / inkFrame().k;
    for (const s of visibleStrokes()) {
      const b = bboxOf(s);
      if (p[0] < b[0] - radius || p[0] > b[2] + radius || p[1] < b[1] - radius || p[1] > b[3] + radius) continue;
      const limit = radius + s.width / 2;
      const pts = s.points;
      const touched = pts.length === 1 ? Math.hypot(p[0] - pts[0][0], p[1] - pts[0][1]) <= limit
        : pts.some((q, i) => i > 0 && distToSegment(p, pts[i - 1], q) <= limit);
      if (touched) {
        state.active.erase.set(s.id, s);
        hit = true;
      }
    }
    if (hit) {
      state.strokes = state.strokes.filter((s) => !state.active.erase.has(s.id));
      redraw();
    }
  }

  // Pen contact must not scroll, zoom, select text or reach the page's own handlers.
  function onTouch(e) {
    if (inBar(e) || passesThrough(e)) return;
    const stylus = [...e.changedTouches].some((t) => t.touchType === 'stylus');
    if (((stylus || state.native?.finger) && canDraw()) || state.active) swallow(e);
  }

  function onMouseLike(e) {
    if (inBar(e) || state.passClick) return;
    if (state.active || performance.now() - state.lastPenEnd < CLICK_GUARD_MS) swallow(e);
  }

  function installInput() {
    const opts = { capture: true, passive: false };
    window.addEventListener('pointerdown', onPointerDown, opts);
    window.addEventListener('pointermove', onPointerMove, opts);
    window.addEventListener('pointerup', onPointerEnd, opts);
    window.addEventListener('pointercancel', onPointerEnd, opts);
    window.addEventListener('touchstart', onTouch, opts);
    window.addEventListener('touchmove', onTouch, opts);
    for (const type of ['click', 'mousedown', 'mouseup', 'dblclick', 'contextmenu', 'auxclick']) window.addEventListener(type, onMouseLike, opts);
    window.addEventListener('selectstart', (e) => state.active && swallow(e), opts);
    window.addEventListener('gesturestart', (e) => state.active && swallow(e), opts);
  }

  // ---------- live preview: in-progress points go straight to other viewers ----------

  function sendLive(a) {
    a.live ??= { sent: 0, inFlight: false, timer: 0, last: 0, end: null };
    const l = a.live;
    if (l.inFlight || l.timer) return;
    const wait = LIVE_INTERVAL_MS - (performance.now() - l.last);
    if (wait > 0) {
      l.timer = setTimeout(() => {
        l.timer = 0;
        sendLive(a);
      }, wait);
      return;
    }
    const s = a.stroke;
    const points = s.points.slice(l.sent);
    if (!points.length && !l.end) return;
    const review = ensureReview();
    const body = {
      clientId: CLIENT_ID,
      meta: { page: review.meta.page, contentVersion: review.meta.contentVersion, viewport: review.meta.viewport },
      stroke: { id: s.id, tool: s.tool, color: s.color, width: s.width, kind: s.kind, state: s.state },
      from: l.sent,
      points,
      done: l.end === 'done',
      cancel: l.end === 'cancel',
    };
    const final = !!l.end;
    l.sent += points.length;
    l.inFlight = true;
    l.last = performance.now();
    fetch(`${API}/reviews/${encodeURIComponent(review.id)}/live`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
      .catch(() => {}) // A lost preview only delays the picture; the stroke itself goes through the queue.
      .finally(() => {
        l.inFlight = false;
        if (final) return;
        if (l.end || l.sent < s.points.length) sendLive(a);
      });
  }

  function finishLive(a, end) {
    if (!a.live) {
      if (end === 'cancel') return;
      a.live = { sent: 0, inFlight: false, timer: 0, last: 0, end: null };
    }
    a.live.end = end;
    clearTimeout(a.live.timer);
    a.live.timer = 0;
    a.live.last = 0;
    if (!a.live.inFlight) sendLive(a);
  }

  function adoptReview(id, meta) {
    // Another device just started the review this page is showing.
    if (state.review || FIXED_REVIEW || !meta) return false;
    const vp = reviewViewport();
    if (meta.page !== PAGE || meta.contentVersion !== VERSION || !sameViewport(meta.viewport, vp)) return false;
    state.review = { id, revision: 0, meta: { page: PAGE, contentVersion: VERSION, viewport: vp, device: navigator.userAgent.slice(0, 200) } };
    try {
      localStorage.setItem(reviewKey(vp), id);
    } catch {
      // The server lookup finds it next time.
    }
    return true;
  }

  function onLive(data) {
    if (data.clientId === CLIENT_ID) return;
    if (!state.review || state.review.id !== data.review) {
      if (!adoptReview(data.review, data.meta)) return;
      refreshFromServer();
    }
    let entry = live.get(data.stroke.id);
    if (data.cancel) {
      if (entry) {
        clearTimeout(entry.timer);
        live.delete(data.stroke.id);
        redraw();
      }
      return;
    }
    if (!entry) {
      entry = { stroke: { ...data.stroke, points: [] }, timer: 0 };
      live.set(data.stroke.id, entry);
    }
    const pts = entry.stroke.points;
    // Requests can arrive out of order; only append the continuation of what is already drawn.
    if (data.from === pts.length) {
      const from = pts.length;
      pts.push(...data.points);
      if (isVisible(entry.stroke) && pts.length) drawIncrement(entry.stroke, from);
    } else if (data.from < pts.length && data.from + data.points.length > pts.length) {
      pts.push(...data.points.slice(pts.length - data.from));
      redraw();
    }
    clearTimeout(entry.timer);
    entry.timer = setTimeout(() => {
      live.delete(data.stroke.id);
      redraw();
    }, LIVE_STALE_MS);
  }

  // Applies one revision's net change; anything out of sequence falls back to a full fetch.
  function onReviewDelta(data) {
    if (!state.review || state.review.id !== data.id) {
      if (!adoptReview(data.id, data)) return;
    }
    if (data.revision <= state.review.revision) return;
    if (data.revision !== state.review.revision + 1 || !Array.isArray(data.added)) {
      refreshFromServer();
      return;
    }
    const removed = new Set(data.removed);
    const byId = new Map(state.serverStrokes.filter((s) => !removed.has(s.id)).map((s) => [s.id, s]));
    for (const s of data.added) {
      byId.set(s.id, s);
      const entry = live.get(s.id);
      if (entry) {
        clearTimeout(entry.timer);
        live.delete(s.id);
      }
    }
    state.serverStrokes = [...byId.values()];
    state.review.revision = data.revision;
    rebuild();
  }

  // ---------- commits and undo ----------

  function copyStroke(s) {
    return { ...cleanStroke(s), id: uid('s_') };
  }

  function addStrokes(list) {
    state.strokes.push(...list);
    redraw();
    return Promise.all(list.map((s) => enqueue({ opId: uid('o_'), type: 'add', stroke: cleanStroke(s) })));
  }

  function eraseStrokes(ids) {
    const set = new Set(ids);
    state.strokes = state.strokes.filter((s) => !set.has(s.id));
    redraw();
    return enqueue({ opId: uid('o_'), type: 'erase', strokeIds: ids });
  }

  function commitAdd(s) {
    state.undo.push({ type: 'add', strokes: [s] });
    state.redo = [];
    addStrokes([s]);
    renderBar();
  }

  function commitErase(strokes) {
    state.undo.push({ type: 'erase', strokes });
    state.redo = [];
    eraseStrokes(strokes.map((s) => s.id));
    renderBar();
  }

  function undo() {
    const entry = state.undo.pop();
    if (!entry) return;
    if (entry.type === 'add') {
      eraseStrokes(entry.strokes.map((s) => s.id));
      state.redo.push(entry);
    } else {
      const copies = entry.strokes.map(copyStroke);
      addStrokes(copies);
      state.redo.push({ type: 'erase', strokes: copies });
    }
    renderBar();
  }

  function redo() {
    const entry = state.redo.pop();
    if (!entry) return;
    if (entry.type === 'add') {
      const copies = entry.strokes.map(copyStroke);
      addStrokes(copies);
      state.undo.push({ type: 'add', strokes: copies });
    } else {
      eraseStrokes(entry.strokes.map((s) => s.id));
      state.undo.push(entry);
    }
    renderBar();
  }

  // ---------- saving and deleting by page (current screen state) or by whole document ----------

  const pageLabel = () => (pageState() ? `이 페이지(${pageState()})` : '이 페이지');

  function clearPage() {
    const shown = visibleStrokes();
    if (!shown.length) return toast('이 페이지에는 필기가 없습니다');
    if (!confirm(`${pageLabel()}의 필기 ${shown.length}획을 지울까요? 실행 취소로 되돌릴 수 있습니다.`)) return;
    commitErase(shown);
  }

  // Every review of this document: all pages, screen sizes and earlier versions. Not undoable.
  async function clearDocument() {
    let info;
    try {
      info = (await (await fetch(`${API}/pages`)).json()).find((p) => p.path === PAGE);
    } catch {
      return toast('맥 서버에 연결할 수 없어 지우지 못했습니다');
    }
    const total = Math.max(info?.strokes ?? 0, state.strokes.length);
    if (!total) return toast('이 문서에는 필기가 없습니다');
    if (!confirm(`${PAGE}의 필기를 모두 지울까요? 모든 페이지·화면 크기·이전 버전의 필기 ${total}획이 지워지며 되돌릴 수 없습니다.`)) return;
    // Unsent strokes of this review are erased through the queue so they cannot arrive after the clear.
    if (state.strokes.length) eraseStrokes(state.strokes.map((s) => s.id));
    state.undo = [];
    state.redo = [];
    try {
      const res = await fetch(`${API}/pages/clear`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ page: PAGE }) });
      const out = await res.json();
      toast(res.ok ? `${out.strokes}획을 지웠습니다` : `지우지 못했습니다: ${out.error}`);
    } catch {
      toast('이 리뷰는 지웠고, 다른 화면 크기의 필기는 연결되면 다시 시도해 주세요');
    }
    renderBar();
  }

  async function saveNotes(scope) {
    await flush();
    const body = scope === 'page' ? { page: PAGE, review: state.review?.id, state: pageState() } : { page: PAGE };
    try {
      const res = await fetch(`${API}/pages/export`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const out = await res.json();
      if (!res.ok) return toast(`저장하지 못했습니다: ${out.error}`);
      toast(out.strokes ? `${out.strokes}획을 맥에 저장했습니다 · ${out.dir}` : '저장할 필기가 없습니다');
    } catch {
      toast('맥 서버에 연결할 수 없어 저장하지 못했습니다');
    }
  }

  async function exportPdf() {
    await flush();
    toast('필기를 넣은 PDF를 만드는 중입니다');
    try {
      const res = await fetch(`${API}/pages/pdf`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ page: PAGE }) });
      if (!res.ok) return toast(`PDF를 만들지 못했습니다: ${(await res.json()).error}`);
      const name = decodeURIComponent((res.headers.get('Content-Disposition') ?? '').split("''")[1] ?? '필기.pdf');
      const blob = await res.blob();
      const saved = decodeURIComponent(res.headers.get('X-Saved') ?? '');
      if (NATIVE) {
        // The app shows the share sheet; message bodies cannot carry a Blob, so the PDF travels as base64.
        const data = await new Promise((resolve) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result).split(',')[1]);
          reader.readAsDataURL(blob);
        });
        NATIVE.postMessage({ type: 'pdf', name, data });
      } else {
        const a = Object.assign(document.createElement('a'), { href: URL.createObjectURL(blob), download: name });
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 60000);
      }
      toast(`${res.headers.get('X-Strokes')}획을 넣은 PDF를 만들었습니다 · 맥 사본 ${saved}`);
    } catch {
      toast('맥 서버에 연결할 수 없어 PDF를 만들지 못했습니다');
    }
  }

  // ---------- reload hold ----------

  function tryReload() {
    if (!state.reloadWanted) return;
    if (state.active || state.idbWrites > 0 || performance.now() - state.lastInput < RELOAD_IDLE_MS) {
      setTimeout(tryReload, 250);
      return;
    }
    try {
      sessionStorage.setItem(`pr:scroll:${location.pathname}`, JSON.stringify([window.scrollX, window.scrollY]));
    } catch {
      // Scroll restore is a convenience only.
    }
    state.selfReload = true;
    location.reload();
  }

  function restoreScroll() {
    try {
      const key = `pr:scroll:${location.pathname}`;
      const saved = sessionStorage.getItem(key);
      if (!saved) return;
      sessionStorage.removeItem(key);
      const [x, y] = JSON.parse(saved);
      window.scrollTo(x, y);
    } catch {
      // Ignore malformed or unavailable storage.
    }
  }

  // ---------- live updates ----------

  function connectEvents() {
    const es = new EventSource('/__pr/events');
    // Fires on every (re)connect: refetch, because SSE does not replay missed events.
    es.addEventListener('hello', () => {
      state.online = true;
      refreshFromServer();
      flush();
    });
    es.addEventListener('reload', () => {
      if (MODE !== 'live') return;
      state.reloadWanted = true;
      tryReload();
    });
    // Browsers allow ~6 connections per host, so the viewer page reuses this stream instead of opening its own.
    const forward = (name, data) => inFrameViewer && parent.postMessage({ type: 'pr-event', name, data }, location.origin);
    es.addEventListener('review', (ev) => {
      const data = JSON.parse(ev.data);
      onReviewDelta(data);
      forward('review', data);
    });
    es.addEventListener('live', (ev) => {
      const data = JSON.parse(ev.data);
      onLive(data);
      forward('live', data);
    });
    es.addEventListener('presence', (ev) => forward('presence', JSON.parse(ev.data)));
    es.addEventListener('navigate', (ev) => {
      const data = JSON.parse(ev.data);
      forward('navigate', data);
      // A page turn sent from the Mac viewer with sync on.
      if (MODE === 'live' && !inFrameViewer && data.clientId !== CLIENT_ID && data.page === PAGE && data.state !== pageState()) {
        location.hash = data.state;
      }
    });
    es.onerror = () => {
      state.online = false;
      renderStatus();
    };
  }

  // ---------- presence: the writing device tells viewers which page and screen it is on ----------

  let presenceTimer = 0;
  function sendPresence() {
    if (!(SHOW_TOOLS || NATIVE) || MODE !== 'live' || inFrameViewer || document.visibilityState !== 'visible') return;
    clearTimeout(presenceTimer);
    // Repeated so a viewer opened later still finds the iPad's current page.
    presenceTimer = setTimeout(sendPresence, 15000);
    const review = ensureReview();
    const { page, contentVersion, viewport: vp } = review.meta;
    fetch(`${API}/presence`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ clientId: CLIENT_ID, review: review.id, meta: { page, contentVersion, viewport: vp }, state: pageState() }),
    }).catch(() => {});
  }

  // ---------- toolbar ----------

  const bar = document.createElement('div');
  bar.id = '__pr-bar';
  const menu = document.createElement('div');
  menu.id = '__pr-menu';
  menu.hidden = true;
  const status = document.createElement('div');
  status.className = '__pr-status';
  const buttons = {};

  const svg = (body, size = 22) => `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
  const ICONS = {
    pen: svg('<path d="M15.5 4.5l4 4L8 20H4v-4z"/><path d="M13 7l4 4"/>'),
    highlighter: svg('<path d="M14 4l6 6-8 8H8v-4z"/><path d="M8 18l-3 2 1-4"/><path d="M4 21h8"/>'),
    eraser: svg('<path d="M8 20h12"/><path d="M4.5 15.5l9-9a2 2 0 012.8 0l3.2 3.2a2 2 0 010 2.8L13 19H8z"/><path d="M10 10l6 6"/>'),
    undo: svg('<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 010 12h-3"/>'),
    redo: svg('<path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 000 12h3"/>'),
    more: svg('<circle cx="5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="19" cy="12" r="1.3" fill="currentColor"/>'),
  };

  function button(key, html, onClick, label) {
    const b = document.createElement('button');
    b.type = 'button';
    b.innerHTML = html;
    if (label) {
      b.title = label;
      b.setAttribute('aria-label', label);
    }
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      onClick(e);
      renderBar();
    });
    buttons[key] = b;
    return b;
  }

  const sep = () => Object.assign(document.createElement('span'), { className: '__pr-sep' });

  const tools = document.createElement('div');
  tools.className = '__pr-tools';
  let barAnimating = false;

  function selectTool(tool) {
    state.tool = tool;
    savePrefs();
  }

  function buildBar() {
    tools.append(
      button('pen', ICONS.pen, () => selectTool('pen'), '펜'),
      button('highlighter', ICONS.highlighter, () => selectTool('highlighter'), '형광펜'),
      button('eraser', ICONS.eraser, () => selectTool('eraser'), '지우개'),
      sep());
    COLORS.forEach((c, i) => {
      const b = button(`color${i}`, '', () => {
        const tool = state.tool === 'eraser' ? lastInk() : state.tool;
        state.prefs[tool].color = c;
        selectTool(tool);
      }, `색 ${c}`);
      b.className = '__pr-swatch';
      b.style.setProperty('--c', c);
      tools.append(b);
    });
    tools.append(sep());
    // Thickness is shown as a line sample in the current color, not as a word.
    for (let i = 0; i < 3; i++) {
      const b = button(`size${i}`, '<svg viewBox="0 0 28 24" width="28" height="24" aria-hidden="true"><line x1="5" y1="12" x2="23" y2="12" stroke-linecap="round"/></svg>', () => setSize(i), ['가늘게', '보통', '굵게'][i]);
      b.className = '__pr-size';
      tools.append(b);
    }
    tools.append(
      sep(),
      button('undo', ICONS.undo, undo, '실행 취소'),
      button('redo', ICONS.redo, redo, '다시 실행'),
      button('more', ICONS.more, () => toggleMenu(), '더보기'));
    buttons.more.classList.add('__pr-more');
    // The toggle sits at the bar's anchored corner, so the bar folds into it and unfolds out of it.
    const toggle = button('collapse', '', () => {
      if (barDrag.justMoved) {
        barDrag.justMoved = false;
        return;
      }
      closeMenu();
      setCollapsed(!bar.hasAttribute('data-collapsed'), true);
    }, '누르면 접기/펴기, 끌면 옮기기');
    toggle.classList.add('__pr-toggle');
    bar.append(tools, toggle);
    buildMenu();
    installBarDrag(toggle);
    let savedPos = null;
    try {
      savedPos = JSON.parse(localStorage.getItem('pr:barpos') || 'null');
    } catch {
      // Default corner.
    }
    applyBarPos(savedPos ?? DEFAULT_BAR_POS);
    let saved = false;
    try {
      saved = localStorage.getItem('pr:collapsed') === '1';
    } catch {
      // Starts expanded.
    }
    setCollapsed(saved, false);
  }

  // ---------- the ⋯ menu: everything that is not drawn with ----------

  function menuItem(key, label, onClick) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    b.addEventListener('click', (e) => {
      e.stopPropagation();
      closeMenu();
      onClick();
      renderBar();
    });
    buttons[key] = b;
    return b;
  }

  function menuGroup(title, ...items) {
    const g = document.createElement('div');
    g.className = '__pr-group';
    if (title) g.append(Object.assign(document.createElement('div'), { className: '__pr-group-title', textContent: title }));
    g.append(...items);
    return g;
  }

  function buildMenu() {
    menu.append(status);
    if (MODE === 'live' && !inFrameViewer) menu.append(menuGroup('', menuItem('home', '문서 목록', () => location.assign('/'))));
    menu.append(
      menuGroup('',
        menuItem('hide', '필기 숨기기', () => {
          state.hidden = !state.hidden;
          redraw();
        }),
        menuItem('mouse', '마우스로 그리기', () => {
          state.mouseDraw = !state.mouseDraw;
          document.documentElement.style.cursor = state.mouseDraw ? 'crosshair' : '';
        })),
      menuGroup('저장', menuItem('savePage', '이 페이지 필기 저장', () => saveNotes('page')), menuItem('saveDoc', '이 문서 필기 전체 저장', () => saveNotes('document')),
        ...(PAGED ? [menuItem('savePdf', 'PDF로 내보내기 (필기 포함)', exportPdf)] : [])),
      menuGroup('지우기', menuItem('clearPage', '이 페이지 필기 지우기', clearPage), menuItem('clearDoc', '이 문서 필기 전부 지우기', clearDocument)));
    buttons.clearPage.classList.add('__pr-danger');
    buttons.clearDoc.classList.add('__pr-danger');
    document.documentElement.append(menu);
    document.addEventListener('pointerdown', (e) => {
      if (!menu.hidden && !menu.contains(e.target) && e.target !== buttons.more && !buttons.more.contains(e.target)) closeMenu();
    }, true);
  }

  // The menu opens from the ⋯ button toward the middle of the screen.
  function toggleMenu() {
    if (!menu.hidden) return closeMenu();
    menu.hidden = false;
    const r = buttons.more.getBoundingClientRect();
    const m = menu.getBoundingClientRect();
    const left = Math.min(Math.max(8, barPos.side === 'right' ? r.right - m.width : r.left), window.innerWidth - m.width - 8);
    const top = barPos.vside === 'bottom' ? r.top - m.height - 8 : r.bottom + 8;
    menu.style.left = `${left}px`;
    menu.style.top = `${Math.max(8, Math.min(top, window.innerHeight - m.height - 8))}px`;
    buttons.more.setAttribute('aria-expanded', 'true');
  }

  function closeMenu() {
    menu.hidden = true;
    buttons.more?.setAttribute('aria-expanded', 'false');
  }

  let toastTimer = 0;
  function toast(text) {
    let t = document.getElementById('__pr-toast');
    if (!t) {
      t = Object.assign(document.createElement('div'), { id: '__pr-toast' });
      t.setAttribute('role', 'status');
      document.documentElement.append(t);
    }
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (t.hidden = true), 3500);
  }

  // ---------- moving the toolbar: drag the toggle; the bar anchors to the nearest screen corner ----------

  const DEFAULT_BAR_POS = { side: 'right', h: 12, vside: 'bottom', v: 12 };
  const TOGGLE_REACH = 25; // half the 40px toggle plus the bar's 5px padding
  const barDrag = { active: null, justMoved: false };
  let barPos = DEFAULT_BAR_POS;

  function applyBarPos(pos) {
    barPos = pos;
    // 'auto' overrides the stylesheet's default right/bottom corner.
    for (const k of ['left', 'right', 'top', 'bottom']) bar.style[k] = 'auto';
    bar.dataset.side = pos.side;
    bar.dataset.vside = pos.vside;
    bar.style[pos.side] = `${pos.h}px`;
    bar.style[pos.vside] = `${pos.v}px`;
    bar.style.maxWidth = `calc(100vw - ${pos.h + 12}px)`;
  }

  // The toggle stays where it was dropped; the rest of the bar opens toward the middle of the screen.
  function posForToggle(cx, cy) {
    const w = window.innerWidth;
    const h = window.innerHeight;
    const x = Math.min(Math.max(cx, TOGGLE_REACH + 4), w - TOGGLE_REACH - 4);
    const y = Math.min(Math.max(cy, TOGGLE_REACH + 4), h - TOGGLE_REACH - 4);
    const side = x < w / 2 ? 'left' : 'right';
    const vside = y < h / 2 ? 'top' : 'bottom';
    return {
      side, h: Math.round(side === 'left' ? x - TOGGLE_REACH : w - x - TOGGLE_REACH),
      vside, v: Math.round(vside === 'top' ? y - TOGGLE_REACH : h - y - TOGGLE_REACH),
    };
  }

  function toggleCenter() {
    const r = buttons.collapse.getBoundingClientRect();
    return [r.left + r.width / 2, r.top + r.height / 2];
  }

  function installBarDrag(toggle) {
    toggle.addEventListener('pointerdown', (e) => {
      if (e.button > 0) return;
      const [cx, cy] = toggleCenter();
      barDrag.active = { id: e.pointerId, x0: e.clientX, y0: e.clientY, cx, cy, moved: false };
      try {
        toggle.setPointerCapture(e.pointerId);
      } catch {
        // Moves are still tracked while the pointer stays on the toggle.
      }
    });
    toggle.addEventListener('pointermove', (e) => {
      const d = barDrag.active;
      if (!d || e.pointerId !== d.id) return;
      const dx = e.clientX - d.x0;
      const dy = e.clientY - d.y0;
      if (!d.moved && Math.hypot(dx, dy) < 8) return;
      d.moved = true;
      closeMenu();
      bar.setAttribute('data-dragging', '');
      applyBarPos(posForToggle(d.cx + dx, d.cy + dy));
    });
    const end = (e) => {
      const d = barDrag.active;
      if (!d || e.pointerId !== d.id) return;
      barDrag.active = null;
      if (!d.moved) return;
      barDrag.justMoved = e.type === 'pointerup';
      bar.removeAttribute('data-dragging');
      try {
        localStorage.setItem('pr:barpos', JSON.stringify(barPos));
      } catch {
        // The position is a convenience only.
      }
    };
    toggle.addEventListener('pointerup', end);
    toggle.addEventListener('pointercancel', end);
    window.addEventListener('resize', () => applyBarPos(posForToggle(...toggleCenter())));
  }

  // clip-path inset that leaves only the toggle (plus the bar's padding) visible.
  function toggleInset() {
    const b = bar.getBoundingClientRect();
    const t = buttons.collapse.getBoundingClientRect();
    const pad = 5;
    const inset = [t.top - b.top - pad, b.right - t.right - pad, b.bottom - t.bottom - pad, t.left - b.left - pad].map((v) => `${Math.max(0, v)}px`);
    return `inset(${inset.join(' ')} round 14px)`;
  }

  function setCollapsed(collapsed, animate) {
    if (barAnimating) return;
    const toggle = buttons.collapse;
    toggle.setAttribute('aria-expanded', String(!collapsed));
    try {
      localStorage.setItem('pr:collapsed', collapsed ? '1' : '0');
    } catch {
      // Remembering the fold is a convenience only.
    }
    const still = !animate || matchMedia('(prefers-reduced-motion: reduce)').matches || !bar.animate;
    if (still) {
      bar.toggleAttribute('data-collapsed', collapsed);
      return;
    }
    const timing = { duration: 280, easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)' };
    const away = `translate(${barPos.side === 'right' ? 16 : -16}px, ${barPos.vside === 'bottom' ? 8 : -8}px) scale(0.94)`;
    barAnimating = true;
    // The state change runs on a timer, not on animation.finished, which never settles while the page is hidden.
    if (collapsed) {
      const fold = bar.animate([{ clipPath: 'inset(0px 0px 0px 0px round 14px)' }, { clipPath: toggleInset() }], { ...timing, fill: 'forwards' });
      const fade = tools.animate([{ opacity: 1, transform: 'none' }, { opacity: 0, transform: away }], { ...timing, duration: 200, fill: 'forwards' });
      setTimeout(() => {
        bar.setAttribute('data-collapsed', '');
        fold.cancel();
        fade.cancel();
        barAnimating = false;
      }, timing.duration);
    } else {
      bar.removeAttribute('data-collapsed');
      bar.animate([{ clipPath: toggleInset() }, { clipPath: 'inset(0px 0px 0px 0px round 14px)' }], timing);
      tools.animate([{ opacity: 0, transform: away }, { opacity: 1, transform: 'none' }], { ...timing, delay: 60, fill: 'backwards' });
      setTimeout(() => {
        barAnimating = false;
      }, timing.duration + 60);
    }
  }

  const lastInk = () => (state.prefs.lastInk === 'highlighter' ? 'highlighter' : 'pen');

  function setSize(size) {
    const tool = state.tool === 'eraser' ? lastInk() : state.tool;
    state.prefs[tool].size = size;
    selectTool(tool);
  }

  function renderBar() {
    if (!buttons.pen) return renderStatus();
    if (state.tool !== 'eraser') state.prefs.lastInk = state.tool;
    const inkTool = state.tool === 'eraser' ? lastInk() : state.tool;
    const ink = state.prefs[inkTool];
    for (const t of ['pen', 'highlighter', 'eraser']) buttons[t].setAttribute('aria-pressed', String(state.tool === t));
    COLORS.forEach((c, i) => buttons[`color${i}`].setAttribute('aria-pressed', String(ink.color === c)));
    for (let i = 0; i < 3; i++) {
      const line = buttons[`size${i}`].querySelector('line');
      const w = WIDTHS[inkTool][i];
      // Highlighter widths are shown scaled down so all three fit the button.
      line.setAttribute('stroke-width', String(inkTool === 'highlighter' ? 3 + i * 2.5 : w));
      line.setAttribute('stroke', ink.color);
      line.setAttribute('stroke-opacity', inkTool === 'highlighter' ? '0.5' : '1');
      buttons[`size${i}`].setAttribute('aria-pressed', String((ink.size ?? 0) === i));
    }
    // Folded, the toggle shows the active tool in its color.
    buttons.collapse.innerHTML = ICONS[state.tool];
    buttons.collapse.style.color = state.tool === 'eraser' ? '' : ink.color;
    buttons.hide.textContent = state.hidden ? '필기 보이기' : '필기 숨기기';
    buttons.mouse.setAttribute('aria-pressed', String(state.mouseDraw));
    buttons.mouse.textContent = state.mouseDraw ? '마우스로 그리기 끄기' : '마우스로 그리기';
    buttons.undo.disabled = !state.undo.length;
    buttons.redo.disabled = !state.redo.length;
    renderStatus();
  }

  function renderStatus() {
    const shown = visibleStrokes().length;
    const parts = [`${viewport.width}×${viewport.height}`, pageState() ? `${pageState()} ${shown}획 (전체 ${state.strokes.length})` : `${shown}획`];
    let warn = false;
    if (MODE === 'snapshot') parts.push(`스냅숏 ${VERSION.slice(0, 6)}`);
    if (FIXED_REVIEW && state.review && !sameViewport(reviewViewport(), state.review.meta.viewport)) {
      parts.push(`리뷰 ${state.review.meta.viewport.width}×${state.review.meta.viewport.height}와 크기 다름 · 보기 전용`);
      warn = true;
    }
    if (state.pending) parts.push(`전송 대기 ${state.pending}`);
    if (state.authLost) {
      parts.push('토큰 필요 · 서버 주소로 다시 열기');
      warn = true;
    } else if (!state.online) {
      parts.push('오프라인');
      warn = true;
    }
    if (state.rejected) {
      parts.push(`거부됨 ${state.rejected}`);
      warn = true;
    }
    status.textContent = parts.join(' · ');
    status.toggleAttribute('data-warn', warn);
    // A dot on ⋯ signals unsent ink or a connection problem without spending toolbar space on text.
    if (buttons.more) buttons.more.dataset.badge = warn ? 'warn' : state.pending ? 'pending' : '';
    NATIVE?.postMessage({
      type: 'state', status: status.textContent, warn, pending: state.pending, hidden: state.hidden,
      canUndo: state.undo.length > 0, canRedo: state.redo.length > 0, page: pageState(), strokes: shown, pdf: PAGED,
    });
  }

  // ---------- InkBridge Pad: its toolbar sets the ink and sends commands ----------

  state.native = null;
  state.setInk = ({ tool, color, width, kind, finger }) => {
    if (['pen', 'highlighter', 'eraser'].includes(tool)) state.tool = tool;
    state.native = { color, width: Number(width), kind, finger: !!finger };
  };
  state.toast = toast; // for messages from the app
  state.command = (name) => {
    const commands = {
      undo, redo, clearPage, clearDocument,
      savePage: () => saveNotes('page'),
      saveDocument: () => saveNotes('document'),
      exportPdf,
      toggleHidden: () => {
        state.hidden = !state.hidden;
        redraw();
      },
      home: () => location.assign('/'),
    };
    commands[name]?.();
    renderStatus();
  };

  // ---------- export mode: full-document SVG for headless screenshots ----------

  function renderExportSvg() {
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    const height = document.documentElement.scrollHeight;
    const width = document.documentElement.clientWidth;
    svg.setAttribute('width', width);
    svg.setAttribute('height', height);
    svg.style.cssText = 'position:absolute;left:0;top:0;pointer-events:none;z-index:2147483000';
    const f = inkFrame();
    const group = document.createElementNS(ns, 'g');
    group.setAttribute('transform', `translate(${f.x} ${f.y}) scale(${f.k})`);
    svg.append(group);
    for (const s of visibleStrokes()) {
      const path = document.createElementNS(ns, 'path');
      path.setAttribute('d', s.points.map(([x, y], i) => `${i ? 'L' : 'M'}${x} ${y}`).join(' '));
      const avg = s.points.reduce((sum, p) => sum + p[2], 0) / s.points.length;
      path.setAttribute('fill', 'none');
      path.setAttribute('stroke', s.color);
      path.setAttribute('stroke-width', s.tool === 'pen' ? s.width * (0.5 + avg) : s.width);
      path.setAttribute('stroke-linecap', 'round');
      path.setAttribute('stroke-linejoin', 'round');
      if (s.tool === 'highlighter') path.setAttribute('stroke-opacity', '0.35');
      group.append(path);
    }
    document.documentElement.append(svg);
    document.fonts?.ready.then(() => (window.__prReady = true)) ?? (window.__prReady = true);
  }

  // ---------- start ----------

  async function start() {
    NATIVE?.postMessage({ type: 'ready' }); // the app answers with its current ink settings
    restoreScroll();
    await selectReview();
    if (EXPORT) return renderExportSvg();
    document.documentElement.append(canvas);
    if (SHOW_TOOLS && !NATIVE) {
      buildBar();
      document.documentElement.append(bar);
      renderBar();
    }
    layoutBand(true);
    installInput();
    connectEvents();
    await refreshPending();
    flush();

    let raf = 0;
    const onView = () => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => layoutBand(false));
    };
    window.addEventListener('scroll', onView, { passive: true });
    window.visualViewport?.addEventListener('scroll', onView);
    window.visualViewport?.addEventListener('resize', onView);
    new ResizeObserver(() => layoutBand(true)).observe(document.body || document.documentElement);

    let resizeTimer = 0;
    window.addEventListener('resize', () => {
      clearTimeout(resizeTimer);
      resizeTimer = setTimeout(async () => {
        const next = measureViewport();
        if (sameViewport(next, viewport)) return layoutBand(true);
        viewport = next;
        // A different viewport means a different layout: switch to that viewport's review (DESIGN.md #1).
        // Page-space ink belongs to the page, not the screen, so it keeps its review.
        if (!FIXED_REVIEW && !PAGE_IMG && !state.active) {
          state.undo = [];
          state.redo = [];
          await selectReview();
          sendPresence();
        }
        layoutBand(true);
        renderBar();
        if (inFrameViewer) parent.postMessage({ type: 'pr-size', clientWidth: viewport.width, height: viewport.height }, location.origin);
      }, 300);
    });

    window.addEventListener('online', flush);
    window.addEventListener('hashchange', () => {
      redraw();
      renderStatus();
      sendPresence();
    });
    document.addEventListener('visibilitychange', sendPresence);
    sendPresence();
    window.addEventListener('beforeunload', (e) => {
      if (state.selfReload) return;
      if (state.idbWrites > 0 || state.active) {
        e.preventDefault();
        e.returnValue = '';
      }
    });
    if (inFrameViewer) parent.postMessage({ type: 'pr-size', clientWidth: viewport.width, height: viewport.height }, location.origin);
  }

  const inFrameViewer = window.parent !== window && FIXED_REVIEW;
  start();
})();
