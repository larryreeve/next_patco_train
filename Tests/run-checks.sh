#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
# XCTest discovers all checks and compiles their shared production sources once.
exec xcrun swift test --disable-swift-testing --scratch-path "${PATCO_CHECK_BUILD:-${TMPDIR:-/tmp}/PATCORegressionBuild}" "$@"
