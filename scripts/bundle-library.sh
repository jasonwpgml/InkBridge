#!/bin/bash
# Copies the library server into a Mac app's Resources (Mac/LibraryHost.swift runs it from there).
# Tests, examples and the compiled helpers in library/bin stay out. Usage: bundle-library.sh <Resources dir>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$1/library"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$ROOT/library/server.mjs" "$ROOT/library/lib" "$ROOT/library/client" "$ROOT/library/scripts" "$DEST/"
