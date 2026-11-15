#!/usr/bin/env bats
load helpers

events() { cat "$GRM_STATE_DIR/events.log"; }

@test "slot gate logs queue admit park unpark and release with the label" {
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 2 --label org/repo-a
  "$GRM_ROOT/bin/job-slots" park --holder "$holder"
  "$GRM_ROOT/bin/job-slots" unpark --holder "$holder"
  "$GRM_ROOT/bin/job-slots" release --holder "$holder"
  run awk '{print $2, $3}' "$GRM_STATE_DIR/events.log"
  [ "$output" = "queue org/repo-a
admit org/repo-a
park org/repo-a
unpark org/repo-a
admit org/repo-a
release org/repo-a" ]
  run awk '$1 !~ /^[0-9]+$/' "$GRM_STATE_DIR/events.log"
  [ -z "$output" ]
}

@test "reaping a dead holder is logged once, and never by status" {
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4 --label org/repo-a
  kill "$first"; wait "$first" || true
  "$GRM_ROOT/bin/job-slots" status > /dev/null
  ! grep -q ' reap ' "$GRM_STATE_DIR/events.log"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 4 --label org/repo-b
  "$GRM_ROOT/bin/job-slots" release --holder "$second"
  [ "$(grep -c ' reap org/repo-a ' "$GRM_STATE_DIR/events.log")" -eq 1 ]
}

@test "admission after the maximum wait is logged as overcommit" {
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4
  GRM_SLOTS_MAX_WAIT=0 "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 4 --label org/repo-b
  grep -q ' overcommit org/repo-b ' "$GRM_STATE_DIR/events.log"
}

@test "slot records carry the time of their last transition" {
  start_holder
  before=$(date +%s)
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 2
  since=$(awk '$1 == "holding" {print $9}' "$GRM_STATE_DIR/slots/state")
  [ "$since" -ge "$before" ] && [ "$since" -le "$(date +%s)" ]
}

@test "records written before the since field existed still load" {
  start_holder
  mkdir -p "$GRM_STATE_DIR/slots"
  : > "$GRM_STATE_DIR/slots/lock"
  printf 'next 8\nholding 7 %s %s 0 0 3 org/repo-a\n' "$holder" "$(awk '{print $22}' "/proc/$holder/stat")" > "$GRM_STATE_DIR/slots/state"
  run "$GRM_ROOT/bin/job-slots" status --raw
  [[ $output == *"3 org/repo-a 0" ]]
}

@test "device lock logs acquire and release" {
  GITHUB_REPOSITORY=org/repo-a GITHUB_JOB=e2e "$GRM_ROOT/bin/with-device-lock" -- true
  run awk '{print $2, $3}' "$GRM_STATE_DIR/events.log"
  [ "$output" = "lock-acquire org/repo-a
lock-release org/repo-a" ]
}

@test "watchdog logs stale holders" {
  bash -c 'exec 17>"$1"; flock 17; sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/leaked"
  processes+=("$(<"$BATS_TEST_TMPDIR/leaked")")
  run "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0
  [ "$status" -eq 1 ]
  grep -q ' stale sleep pid ' "$GRM_STATE_DIR/events.log"
}

@test "the event log is bounded and keeps the newest entries" {
  # shellcheck source=lib/common.sh
  source "$GRM_ROOT/lib/common.sh"
  GRM_EVENTS_MAX=5
  for number in 1 2 3 4 5 6 7 8 9 10 11; do log_event test org/repo-a "entry $number"; done
  [ "$(wc -l < "$GRM_STATE_DIR/events.log")" -eq 5 ]
  [[ $(tail -n 1 "$GRM_STATE_DIR/events.log") == *'entry 11' ]]
}

@test "GRM_EVENTS_MAX=0 disables the event log" {
  start_holder
  GRM_EVENTS_MAX=0 "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  [ ! -e "$GRM_STATE_DIR/events.log" ]
}

@test "a failing event log never fails a gate" {
  start_holder
  mkdir -p "$GRM_STATE_DIR/events.log"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  has_record holding "$holder"
}

@test "a held event log lock drops the event instead of blocking the gate" {
  mkdir -p "$GRM_STATE_DIR"
  flock "$GRM_STATE_DIR/events.lock" sleep 300 &
  processes+=("$!")
  wait_for bash -c '! flock -n "$1" true' _ "$GRM_STATE_DIR/events.lock"
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 2 --label org/repo-a
  has_record holding "$holder"
  [ ! -s "$GRM_STATE_DIR/events.log" ]
}
