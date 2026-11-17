#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib/common.sh"
cd "$GRM_ROOT"
# The tag is mutable; the commit it named when pinned is not. Checked on
# every run, so an installation from before the check is verified too.
bats_tag=v1.11.1 bats_commit=b640ec3cf2c7c9cfc9e6351479261186f76eeec8
if [[ ! -x test/vendor/bats-core/bin/bats ]]; then
  mkdir -p test/vendor
  git clone --depth 1 --branch "$bats_tag" https://github.com/bats-core/bats-core.git test/vendor/bats-core
fi
head=$(git -C test/vendor/bats-core rev-parse HEAD)
if [[ $head != "$bats_commit" ]]; then
  error "fetch-test-deps: test/vendor/bats-core is at $head, not $bats_tag ($bats_commit); delete it and fetch again"
  exit 1
fi
