#!/bin/bash
# Every automated check in the repository: Mac+iPad protocol and Mac compile, library server, Sidecar version.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/check.sh
(cd library && node --test 'test/*.test.mjs')
./sidecar/test.sh
