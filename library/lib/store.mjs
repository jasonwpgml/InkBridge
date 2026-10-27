import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { toRelative } from './paths.mjs';

export const SCHEMA = 1;
const REVIEW_ID = /^r_[A-Za-z0-9_-]{6,40}$/;
const STROKE_ID = /^s_[A-Za-z0-9_-]{6,40}$/;
const OP_ID = /^o_[A-Za-z0-9_-]{6,40}$/;
const VERSION = /^[0-9a-f]{16}$/;
const COLOR = /^#[0-9a-f]{6}$/i;
const TOOLS = new Set(['pen', 'highlighter']);
const PEN_KINDS = new Set(['gel', 'ballpoint', 'fountain']); // InkBridge Pad pen types
const MAX_POINTS = 20000;
const MAX_OPS = 500;
const CLIENT_ID = /^c_[A-Za-z0-9_-]{6,40}$/;

export class ValidationError extends Error {
  status = 400;
}

function check(cond, message) {
  if (!cond) throw new ValidationError(message);
}

const isNum = (v, min, max) => typeof v === 'number' && Number.isFinite(v) && v >= min && v <= max;
const isStr = (v, max) => typeof v === 'string' && v.length <= max;

export function isReviewId(id) {
  return REVIEW_ID.test(id);
}

export function validateMeta(meta) {
  check(meta && typeof meta === 'object', 'meta required');
  check(isStr(meta.page, 1000), 'meta.page');
  let page;
  try {
    page = toRelative(meta.page);
  } catch {
    throw new ValidationError('meta.page');
  }
  check(VERSION.test(meta.contentVersion), 'meta.contentVersion');
  const vp = meta.viewport;
  check(vp && Number.isInteger(vp.width) && Number.isInteger(vp.height), 'meta.viewport');
  check(isNum(vp.width, 100, 10000) && isNum(vp.height, 100, 10000), 'meta.viewport');
  check(meta.device === undefined || isStr(meta.device, 200), 'meta.device');
  return { page, contentVersion: meta.contentVersion, viewport: { width: vp.width, height: vp.height }, device: meta.device ?? '' };
}

export function validateStroke(s) {
  check(s && typeof s === 'object', 'stroke');
  check(STROKE_ID.test(s.id), 'stroke.id');
  check(TOOLS.has(s.tool), 'stroke.tool');
  check(COLOR.test(s.color), 'stroke.color');
  check(isNum(s.width, 0.5, 60), 'stroke.width');
  check(Array.isArray(s.points) && s.points.length >= 1 && s.points.length <= MAX_POINTS, 'stroke.points');
  const points = s.points.map((p) => {
    check(isPoint(p), 'stroke.points[]');
    return [p[0], p[1], p[2]];
  });
  const anchors = s.anchors ?? [];
  check(Array.isArray(anchors) && anchors.length <= 8, 'stroke.anchors');
  for (const a of anchors) {
    check(a && isStr(a.selector, 400) && isStr(a.text, 400), 'stroke.anchors[]');
    check(Array.isArray(a.rect) && a.rect.length === 4 && a.rect.every((v) => isNum(v, -1e5, 1e7)), 'stroke.anchors[].rect');
  }
  check(s.context === undefined || isStr(s.context, 600), 'stroke.context');
  check(s.state === undefined || isStr(s.state, 200), 'stroke.state');
  check(s.kind === undefined || PEN_KINDS.has(s.kind), 'stroke.kind');
  check(isStr(s.createdAt, 40), 'stroke.createdAt');
  return {
    id: s.id, tool: s.tool, color: s.color, width: s.width, ...(s.kind ? { kind: s.kind } : {}), points,
    anchors: anchors.map((a) => ({ selector: a.selector, text: a.text, rect: a.rect })),
    context: s.context ?? '', createdAt: s.createdAt, state: s.state ?? '',
  };
}

const isPoint = (p) => Array.isArray(p) && p.length === 3 && isNum(p[0], -1e5, 1e6) && isNum(p[1], -1e5, 1e7) && isNum(p[2], 0, 1);

// In-progress points relayed to viewers; never stored, so only shape is checked.
export function validateLive(body) {
  check(body && CLIENT_ID.test(body.clientId), 'clientId');
  const s = body.stroke;
  check(s && STROKE_ID.test(s.id) && TOOLS.has(s.tool) && COLOR.test(s.color) && isNum(s.width, 0.5, 60), 'stroke');
  check(s.state === undefined || isStr(s.state, 200), 'stroke.state');
  check(s.kind === undefined || PEN_KINDS.has(s.kind), 'stroke.kind');
  check(Number.isInteger(body.from) && body.from >= 0 && body.from <= MAX_POINTS, 'from');
  check(Array.isArray(body.points) && body.points.length <= 2000 && body.points.every(isPoint), 'points');
  return {
    clientId: body.clientId,
    meta: body.meta ? validateMeta(body.meta) : null,
    stroke: { id: s.id, tool: s.tool, color: s.color, width: s.width, ...(s.kind ? { kind: s.kind } : {}), state: s.state ?? '' },
    from: body.from,
    points: body.points.map((p) => [p[0], p[1], p[2]]),
    done: body.done === true,
    cancel: body.cancel === true,
  };
}

// Which page a writing device is showing; relayed to viewers, kept only in memory.
export function validatePresence(body) {
  check(body && CLIENT_ID.test(body.clientId), 'clientId');
  check(isReviewId(body.review), 'review');
  check(body.state === undefined || isStr(body.state, 200), 'state');
  return { clientId: body.clientId, review: body.review, meta: validateMeta(body.meta), state: body.state ?? '' };
}

export function validateNavigate(body) {
  check(body && CLIENT_ID.test(body.clientId), 'clientId');
  check(isStr(body.page, 1000) && isStr(body.state, 200), 'navigate');
  return { clientId: body.clientId, page: body.page, state: body.state };
}

function validateOp(op) {
  check(op && OP_ID.test(op.opId), 'op.opId');
  if (op.type === 'add') return { opId: op.opId, type: 'add', stroke: validateStroke(op.stroke) };
  if (op.type === 'erase') {
    check(Array.isArray(op.strokeIds) && op.strokeIds.length <= 5000 && op.strokeIds.every((id) => STROKE_ID.test(id)), 'op.strokeIds');
    return { opId: op.opId, type: 'erase', strokeIds: op.strokeIds };
  }
  throw new ValidationError('op.type');
}

export async function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.${crypto.randomBytes(4).toString('hex')}.tmp`;
  const handle = await fs.open(tmp, 'w');
  try {
    await handle.writeFile(text);
    await handle.sync();
  } finally {
    await handle.close();
  }
  await fs.rename(tmp, file);
}

export function publicReview(r) {
  const { appliedOps, ...rest } = r;
  return rest;
}

export class ReviewStore {
  constructor(dataDir) {
    this.dir = path.join(dataDir, 'reviews');
    this.cache = new Map();
    this.queues = new Map();
  }

  async init() {
    await fs.mkdir(this.dir, { recursive: true });
    for (const name of await fs.readdir(this.dir)) {
      if (!name.endsWith('.json')) continue;
      try {
        const r = JSON.parse(await fs.readFile(path.join(this.dir, name), 'utf8'));
        if (r.schema === SCHEMA && isReviewId(r.id)) this.cache.set(r.id, r);
      } catch {
        // A corrupt file is left on disk untouched and skipped.
      }
    }
  }

  get(id) {
    return this.cache.get(id) ?? null;
  }

  list({ page, version, width, height } = {}) {
    return [...this.cache.values()]
      .filter((r) => (!page || r.page === page) && (!version || r.contentVersion === version)
        && (!width || r.viewport.width === width) && (!height || r.viewport.height === height))
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .map((r) => ({ id: r.id, page: r.page, contentVersion: r.contentVersion, viewport: r.viewport,
        revision: r.revision, strokes: r.strokes.length, createdAt: r.createdAt, updatedAt: r.updatedAt, device: r.device }));
  }

  // Ops for one review run one at a time so revisions and file writes never interleave.
  applyOps(id, meta, ops) {
    const prev = this.queues.get(id) ?? Promise.resolve();
    const next = prev.catch(() => {}).then(() => this.#apply(id, meta, ops));
    this.queues.set(id, next);
    return next;
  }

  async #apply(id, rawMeta, rawOps) {
    check(isReviewId(id), 'review id');
    check(Array.isArray(rawOps) && rawOps.length <= MAX_OPS, 'ops');
    const ops = rawOps.map(validateOp);
    const cached = this.cache.get(id);
    const now = new Date().toISOString();
    // Work on a copy so a failed write leaves the cache matching the file on disk.
    const review = cached ? structuredClone(cached)
      : { schema: SCHEMA, id, ...validateMeta(rawMeta), createdAt: now, updatedAt: now, revision: 0, strokes: [], erased: [], appliedOps: [] };
    const applied = new Set(review.appliedOps);
    const erased = new Set(review.erased);
    let changed = 0;
    let recorded = 0;
    for (const op of ops) {
      if (applied.has(op.opId)) continue;
      applied.add(op.opId);
      recorded++;
      review.appliedOps.push(op.opId);
      if (op.type === 'add') {
        if (erased.has(op.stroke.id) || review.strokes.some((s) => s.id === op.stroke.id)) continue;
        review.strokes.push(op.stroke);
        changed++;
      } else {
        const ids = new Set(op.strokeIds);
        for (const sid of ids) {
          if (!erased.has(sid)) {
            erased.add(sid);
            review.erased.push(sid);
          }
        }
        const before = review.strokes.length;
        review.strokes = review.strokes.filter((s) => !ids.has(s.id));
        changed += before - review.strokes.length;
      }
    }
    if (!cached || recorded) {
      if (changed) review.revision++;
      review.updatedAt = now;
      await writeAtomic(path.join(this.dir, `${id}.json`), JSON.stringify(review));
      this.cache.set(id, review);
    }
    // Net change of this batch, so viewers can apply it without refetching the whole review.
    const before = new Set((cached?.strokes ?? []).map((s) => s.id));
    const after = new Set(review.strokes.map((s) => s.id));
    const added = review.strokes.filter((s) => !before.has(s.id));
    const removed = [...before].filter((sid) => !after.has(sid));
    return { revision: review.revision, changed, added, removed };
  }
}
