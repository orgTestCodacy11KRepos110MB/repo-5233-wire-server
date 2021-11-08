#!/usr/bin/env bash
set -euo pipefail

TOP_LEVEL="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"

cd "$TOP_LEVEL"

{
 echo -e "\n-- Changes by ./tools/convert-to-cabal/generate.sh \n\ntests: True\n\n"
 ./hack/bin/cabal-project-local-template.sh "ghc-options: -Werror" >> ./cabal.project
} >> ./cabal.project