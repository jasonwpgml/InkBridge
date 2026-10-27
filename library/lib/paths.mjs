import fs from 'node:fs/promises';
import path from 'node:path';

export class PathError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

// Turns a URL pathname into a path relative to root, or throws PathError.
// Rejects bad encoding, NUL, traversal and any dot-segment (.git, .env, .pencil-review).
export function toRelative(urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath);
  } catch {
    throw new PathError(400, 'bad encoding');
  }
  if (decoded.includes('\0') || decoded.includes('\\')) throw new PathError(400, 'bad path');
  const parts = decoded.split('/').filter(Boolean);
  for (const part of parts) {
    if (part.startsWith('.')) throw new PathError(404, 'hidden path');
  }
  return parts.join('/');
}

// Resolves rel under root and checks that symlinks do not escape it.
export async function resolveInside(rootReal, rel) {
  const target = path.resolve(rootReal, rel);
  if (!isInside(rootReal, target)) throw new PathError(403, 'outside root');
  let real;
  try {
    real = await fs.realpath(target);
  } catch {
    throw new PathError(404, 'not found');
  }
  if (!isInside(rootReal, real)) throw new PathError(403, 'outside root');
  return real;
}

export function isInside(rootReal, target) {
  return target === rootReal || target.startsWith(rootReal + path.sep);
}

export function isIgnoredForWatch(rel) {
  const parts = rel.split(/[\\/]/);
  return parts.some((p) => p.startsWith('.') || p === 'node_modules');
}
