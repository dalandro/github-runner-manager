#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
cd "$GRM_ROOT"
if [[ ! -x test/vendor/bats-core/bin/bats ]]; then
  mkdir -p test/vendor
  git clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git test/vendor/bats-core
fi
