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

@test "state files are private to the account by default" {
  start_holder
  umask 022
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  export GRM_DEVICE_LOCK=$GRM_STATE_DIR/device.lock
  "$GRM_ROOT/bin/with-device-lock" -- bash -c 'stat -c %a "$1.holder" > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/holder-mode"
  "$GRM_ROOT/bin/job-slots" release --holder "$holder"
  [ "$(stat -c %a "$GRM_STATE_DIR")" = 700 ]
  [ "$(stat -c %a "$GRM_STATE_DIR/slots")" = 700 ]
  for file in slots/state slots/lock events.log events.lock device.lock; do
    [ "$(stat -c %a "$GRM_STATE_DIR/$file")" = 600 ]
  done
  [ "$(<"$BATS_TEST_TMPDIR/holder-mode")" = 600 ]
}

@test "the command a job wraps keeps the job's own umask" {
  umask 022
  run "$GRM_ROOT/bin/with-device-lock" -- bash -c umask
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = 0022 ]
}

@test "GRM_UMASK widens state to a group and must be an octal mask" {
  start_holder
  GRM_UMASK=007 "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  [ "$(stat -c %a "$GRM_STATE_DIR/slots")" = 770 ]
  [ "$(stat -c %a "$GRM_STATE_DIR/slots/state")" = 660 ]
  for mask in 7 0778 u=rwx '077;id'; do
    GRM_UMASK=$mask run "$GRM_ROOT/bin/job-slots" status
    [ "$status" -eq 2 ]
    [[ $output == *GRM_UMASK* ]]
  done
}

@test "planted symlinks in the state directory never truncate or append to their targets" {
  start_holder
  mkdir -p "$GRM_STATE_DIR/slots"
  export GRM_DEVICE_LOCK=$GRM_STATE_DIR/device.lock
  for name in slots-lock events-log events-lock device-lock holder; do
    printf 'secret %s\n' "$name" > "$BATS_TEST_TMPDIR/target-$name"
  done
  ln -s "$BATS_TEST_TMPDIR/target-slots-lock" "$GRM_STATE_DIR/slots/lock"
  ln -s "$BATS_TEST_TMPDIR/target-events-log" "$GRM_STATE_DIR/events.log"
  ln -s "$BATS_TEST_TMPDIR/target-events-lock" "$GRM_STATE_DIR/events.lock"
  ln -s "$BATS_TEST_TMPDIR/target-device-lock" "$GRM_DEVICE_LOCK"
  ln -s "$BATS_TEST_TMPDIR/target-holder" "$GRM_DEVICE_LOCK.holder"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  GRM_DEVICE_LOCK_PARK=0 "$GRM_ROOT/bin/with-device-lock" -- true
  "$GRM_ROOT/bin/job-slots" release --holder "$holder"
  for name in slots-lock events-log events-lock device-lock holder; do
    [ "$(<"$BATS_TEST_TMPDIR/target-$name")" = "secret $name" ]
  done
}
