#!/usr/bin/env bats
load helpers

@test "dependency fetch is pinned and skips an existing installation" {
  mkdir -p "$BATS_TEST_TMPDIR/toolkit/scripts" "$BATS_TEST_TMPDIR/toolkit/lib" "$BATS_TEST_TMPDIR/stubs"
  cp "$GRM_ROOT/scripts/fetch-test-deps.sh" "$BATS_TEST_TMPDIR/toolkit/scripts/"
  cp "$GRM_ROOT/lib/common.sh" "$BATS_TEST_TMPDIR/toolkit/lib/"
  export FETCH_LOG="$BATS_TEST_TMPDIR/fetch-log"
  cat > "$BATS_TEST_TMPDIR/stubs/git" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FETCH_LOG"
mkdir -p test/vendor/bats-core/bin
printf '#!/usr/bin/env bash\n' > test/vendor/bats-core/bin/bats
chmod +x test/vendor/bats-core/bin/bats
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/stubs/git"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  "$BATS_TEST_TMPDIR/toolkit/scripts/fetch-test-deps.sh"
  "$BATS_TEST_TMPDIR/toolkit/scripts/fetch-test-deps.sh"
  [ "$(wc -l < "$FETCH_LOG")" -eq 1 ]
  grep -F 'clone --depth 1 --branch v1.11.1 https://github.com/bats-core/bats-core.git test/vendor/bats-core' "$FETCH_LOG"
}
