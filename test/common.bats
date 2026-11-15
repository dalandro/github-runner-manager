#!/usr/bin/env bats
load helpers

@test "identity matches live processes and rejects reused identities" {
  start_holder
  # shellcheck source=../lib/common.sh
  source "$GRM_ROOT/lib/common.sh"
  start=$(get_start_time "$holder")
  [[ $start =~ ^[0-9]+$ ]]
  is_alive "$holder" "$start"
  ! is_alive "$holder" 0
  kill "$holder"
  wait "$holder" || true
  [[ -z $(get_start_time "$holder") ]]
}

@test "identity parses comm containing spaces and parentheses" {
  cp "$(command -v bash)" "$BATS_TEST_TMPDIR/odd ) ( name)"
  "$BATS_TEST_TMPDIR/odd ) ( name)" -c 'echo ready > "$1"; sleep 300 & wait' _ "$BATS_TEST_TMPDIR/ready" &
  process=$!
  processes+=("$process")
  # shellcheck source=../lib/common.sh
  source "$GRM_ROOT/lib/common.sh"
  wait_for test -f "$BATS_TEST_TMPDIR/ready"
  [ "$(<"/proc/$process/comm")" = 'odd ) ( name)' ]
  [[ $(get_start_time "$process") =~ ^[0-9]+$ ]]
}

@test "configuration uses environment then file then defaults" {
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config"
  printf 'GRM_SLOTS_CAPACITY=7\nGRM_MIN_MEM_MB=512\n' > "$GRM_CONFIG"
  run bash -c 'source "$GRM_ROOT/lib/common.sh"; echo "$GRM_SLOTS_CAPACITY $GRM_MIN_MEM_MB $GRM_DEVICE_LOCK_TIMEOUT"'
  [ "$status" -eq 0 ]
  [ "$output" = '4 512 3600' ]
}

@test "worker discovery walks ancestors" {
  cp "$(command -v bash)" "$BATS_TEST_TMPDIR/Runner.Worker"
  cat > "$BATS_TEST_TMPDIR/worker" <<'SCRIPT'
#!/usr/bin/env bash
bash -c 'source "$GRM_ROOT/lib/common.sh"; find_worker_pid' > "$1"
exit 0
SCRIPT
  "$BATS_TEST_TMPDIR/Runner.Worker" "$BATS_TEST_TMPDIR/worker" "$BATS_TEST_TMPDIR/found" &
  worker=$!
  processes+=("$worker")
  wait "$worker"
  [ "$(<"$BATS_TEST_TMPDIR/found")" = "$worker" ]
}

@test "device cancellation defaults to a short grace period" {
  run env -u GRM_DEVICE_LOCK_GRACE bash -c 'source "$GRM_ROOT/lib/common.sh"; echo "$GRM_DEVICE_LOCK_GRACE"'
  [ "$status" -eq 0 ]
  [ "$output" = 5 ]
}

@test "built-in and example defaults use generic capacity wait and kill policy" {
  for config in /dev/null "$GRM_ROOT/config.example.env"; do
    run env -u GRM_SLOTS_CAPACITY -u GRM_SLOTS_MAX_WAIT -u GRM_DEVICE_LOCK_TIMEOUT \
      -u GRM_WATCHDOG_KILL_ALLOW GRM_CONFIG="$config" bash -c '
        source "$GRM_ROOT/lib/common.sh"
        printf "%s %s %s <%s>\n" "$GRM_SLOTS_CAPACITY" "$GRM_SLOTS_MAX_WAIT" "$GRM_DEVICE_LOCK_TIMEOUT" "$GRM_WATCHDOG_KILL_ALLOW"
      '
    [ "$status" -eq 0 ]
    [ "$output" = '6 2700 3600 <>' ]
  done
}
