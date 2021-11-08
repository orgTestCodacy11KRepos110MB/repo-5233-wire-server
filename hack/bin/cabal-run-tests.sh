#!/usr/bin/env bash
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TOP_LEVEL="$(cd "$DIR/../.." && pwd)"

pkgName=${1:-Please specify package name}

# This is required because some tests (e.g. golden tests) depend on the path
# where they are run from.
pkgDir=$(find "$TOP_LEVEL" -name "$pkgName.cabal" | grep -v dist-newstyle | head -1 | xargs -n 1 dirname)
cd "$pkgDir"

cabal-plan list-bins "$pkgName"':test:*' | awk '{print $2}' | xargs --no-run-if-empty -n 1 bash -c