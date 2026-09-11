#!/bin/zsh
emulate -L zsh
set -euo pipefail
ROOT="$(cd -P "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
swift run MacStorageLens
