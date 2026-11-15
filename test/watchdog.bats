#!/usr/bin/env bats
load helpers

leak_lock() {
  bash -c 'exec 17>"$1"; flock 17; sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/leaked"
  leaked=$(<"$BATS_TEST_TMPDIR/leaked")
  processes+=("$leaked")
  ! flock -n "$GRM_DEVICE_LOCK" true
}

@test "watchdog detects inherited flock descriptors without killing by default" {
  leak_lock
  run "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0
  [ "$status" -eq 1 ]
  [[ $output == *"stale: pid $leaked (sleep,"* && $output == *'via fd 17'* ]]
  [[ $output == *'holder file missing or holder dead'* ]]
  kill -0 "$leaked"
}

@test "kill mode terminates only allow-listed processes" {
  leak_lock
  run env GRM_WATCHDOG_KILL_ALLOW=adb "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0 --kill
  [ "$status" -eq 1 ]
  [[ $output == *'not killed: not allow-listed'* ]]
  kill -0 "$leaked"
  run env GRM_WATCHDOG_KILL_ALLOW=sleep "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0 --kill
  [ "$status" -eq 1 ]
  wait_for flock -n "$GRM_DEVICE_LOCK" true
}

@test "minimum process age suppresses recent leaks" {
  leak_lock
  run "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 600
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "legitimate wrapper is not stale" {
  "$GRM_ROOT/bin/with-device-lock" -- sleep 300 > "$BATS_TEST_TMPDIR/output" 2>&1 &
  wrapper=$!; processes+=("$wrapper")
  wait_for test -s "$GRM_DEVICE_LOCK.holder"
  run "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  kill -TERM "$wrapper"
  wait "$wrapper" || [ "$?" -eq 143 ]
}

@test "kill mode with an empty allow-list reports that it kills nothing" {
  leak_lock
  run env GRM_WATCHDOG_KILL_ALLOW= "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0 --kill
  [ "$status" -eq 1 ]
  [[ $output == *'empty allow-list; no processes will be killed'* ]]
  [[ $output == *'not killed: not allow-listed'* ]]
  kill -0 "$leaked"
}
