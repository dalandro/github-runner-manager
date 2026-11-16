#!/usr/bin/env bats
load helpers

start_lock() {
  "$GRM_ROOT/bin/with-device-lock" -- bash -c 'echo ready > "$1"; read -r _ < "$2"' _ "$BATS_TEST_TMPDIR/ready" "$BATS_TEST_TMPDIR/finish" > "$BATS_TEST_TMPDIR/lock-output" 2>&1 &
  wrapper=$!
  processes+=("$wrapper")
  wait_for test -f "$BATS_TEST_TMPDIR/ready"
}

@test "device lock serializes commands and records the holder" {
  mkfifo "$BATS_TEST_TMPDIR/finish"
  start_lock
  [ -s "$GRM_DEVICE_LOCK.holder" ]
  "$GRM_ROOT/bin/with-device-lock" -- bash -c 'echo done > "$1"' _ "$BATS_TEST_TMPDIR/second" &
  second=$!; processes+=("$second")
  sleep 0.1
  [ ! -f "$BATS_TEST_TMPDIR/second" ]
  echo finish > "$BATS_TEST_TMPDIR/finish"
  wait "$wrapper"
  wait "$second"
  [ -f "$BATS_TEST_TMPDIR/second" ]
  [ ! -e "$GRM_DEVICE_LOCK.holder" ]
  flock -n "$GRM_DEVICE_LOCK" true
}

@test "timeout exits 75 and never names the other job in this job's log" {
  mkfifo "$BATS_TEST_TMPDIR/finish"
  GITHUB_REPOSITORY=org/repo-a GITHUB_JOB=secret-job start_lock
  GITHUB_REPOSITORY=org/repo-b run "$GRM_ROOT/bin/with-device-lock" --timeout 0.1 -- true
  [ "$status" -eq 75 ]
  [[ $output == *'::notice::'*'held by another job'* && $output == *'::error::'*'held by another job'* ]]
  [[ $output != *'repo-a'* && $output != *'secret-job'* ]]
  grep -q 'org/repo-a' "$GRM_DEVICE_LOCK.holder"
  echo finish > "$BATS_TEST_TMPDIR/finish"
  wait "$wrapper"
}

@test "descendants never inherit the lock descriptor" {
  "$GRM_ROOT/bin/with-device-lock" -- bash -c 'sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$1"' _ "$BATS_TEST_TMPDIR/descendant"
  descendant=$(<"$BATS_TEST_TMPDIR/descendant")
  processes+=("$descendant")
  kill -0 "$descendant"
  flock -n "$GRM_DEVICE_LOCK" true
  for descriptor in /proc/"$descendant"/fd/*; do
    [[ $(readlink "$descriptor") != "$GRM_DEVICE_LOCK" ]]
  done
}

start_signal_child() {
  env --default-signal=INT "$GRM_ROOT/bin/with-device-lock" -- bash -c '
    if [[ $2 == ignore ]]; then trap "" TERM; else trap '\''echo term > "$1/term"; sleep 1; echo stopped > "$1/stopped"; exit 0'\'' TERM; fi
    trap '\''echo int > "$1/int"; exit 0'\'' INT
    trap '\''echo hup > "$1/hup"; exit 0'\'' HUP
    echo $$ > "$1/child"
    for attempt in {1..300}; do sleep 0.05; done
    exit 1
  ' _ "$BATS_TEST_TMPDIR" "$1" > "$BATS_TEST_TMPDIR/signal-output" 2>&1 &
  wrapper=$!; processes+=("$wrapper")
  wait_for test -s "$BATS_TEST_TMPDIR/child"
  child=$(<"$BATS_TEST_TMPDIR/child"); processes+=("$child")
}

@test "TERM keeps the lock held during child shutdown" {
  export GRM_DEVICE_LOCK_GRACE=3
  start_signal_child handle
  kill -TERM "$wrapper"
  wait_for test -f "$BATS_TEST_TMPDIR/term"
  sleep 0.2
  [ ! -e "$BATS_TEST_TMPDIR/stopped" ]
  run flock -n "$GRM_DEVICE_LOCK" true
  [ "$status" -eq 1 ]
  result=0; wait "$wrapper" || result=$?
  [ "$result" -eq 143 ]
  [ -f "$BATS_TEST_TMPDIR/stopped" ]
  flock -n "$GRM_DEVICE_LOCK" true
  [ ! -e "$GRM_DEVICE_LOCK.holder" ]
}

@test "INT reaches the child INT trap" {
  start_signal_child handle
  kill -INT "$wrapper"
  result=0; wait "$wrapper" || result=$?
  [ "$result" -eq 130 ]
  [ -f "$BATS_TEST_TMPDIR/int" ]
  flock -n "$GRM_DEVICE_LOCK" true
}

@test "cancel kills an uncooperative child after grace" {
  export GRM_DEVICE_LOCK_GRACE=1
  start_signal_child ignore
  started=$SECONDS
  kill -TERM "$wrapper"
  sleep 0.15
  ! flock -n "$GRM_DEVICE_LOCK" true
  result=0; wait "$wrapper" || result=$?
  [ "$result" -eq 143 ]
  # The child would run ~15 s on its own; only the grace kill ends it this soon.
  [ $((SECONDS - started)) -le 4 ]
  ! kill -0 "$child" 2>/dev/null
  flock -n "$GRM_DEVICE_LOCK" true
}

@test "stdin and exit status pass through" {
  run bash -c 'printf "input\n" | "$GRM_ROOT/bin/with-device-lock" -- bash -c '\''read -r line; echo "$line"; exit 23'\'''
  [ "$status" -eq 23 ]
  [ "$output" = input ]
}

@test "cancel while waiting terminates the waiter without disturbing the holder" {
  mkfifo "$BATS_TEST_TMPDIR/finish"
  start_lock
  "$GRM_ROOT/bin/with-device-lock" -- true > "$BATS_TEST_TMPDIR/waiting" 2>&1 &
  waiting=$!; processes+=("$waiting")
  wait_for test -s "$BATS_TEST_TMPDIR/waiting"
  kill -TERM "$waiting"
  result=0; wait "$waiting" || result=$?
  [ "$result" -eq 143 ]
  ! flock -n "$GRM_DEVICE_LOCK" true
  echo finish > "$BATS_TEST_TMPDIR/finish"
  wait "$wrapper"
}

@test "waiting for device parks slots then restores them before running" {
  mkfifo "$BATS_TEST_TMPDIR/finish" "$BATS_TEST_TMPDIR/second-finish"
  start_lock
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4
  GRM_SLOTS_HOLDER=$first "$GRM_ROOT/bin/with-device-lock" -- bash -c 'echo ready > "$1"; read -r _ < "$2"' _ "$BATS_TEST_TMPDIR/second-ready" "$BATS_TEST_TMPDIR/second-finish" > "$BATS_TEST_TMPDIR/parking" 2>&1 &
  waiting=$!; processes+=("$waiting")
  wait_for has_record parked "$first"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 4
  echo finish > "$BATS_TEST_TMPDIR/finish"
  wait "$wrapper"
  [ ! -f "$BATS_TEST_TMPDIR/second-ready" ]
  "$GRM_ROOT/bin/job-slots" release --holder "$second"
  wait_for test -f "$BATS_TEST_TMPDIR/second-ready"
  has_record holding "$first"
  echo finish > "$BATS_TEST_TMPDIR/second-finish"
  wait "$waiting"
}

@test "wrapped commands inherit neither ignored INT nor ignored QUIT" {
  run env --default-signal=INT,QUIT "$GRM_ROOT/bin/with-device-lock" -- \
    awk '$1 == "SigIgn:" {print $2; exit}' /proc/self/status
  [ "$status" -eq 0 ]
  [[ $output =~ ^[0-9a-fA-F]+$ ]]
  (( (16#$output & 6) == 0 ))
}

@test "HUP reaches the child HUP trap" {
  start_signal_child handle
  kill -HUP "$wrapper"
  result=0; wait "$wrapper" || result=$?
  [ "$result" -eq 129 ]
  [ -f "$BATS_TEST_TMPDIR/hup" ]
  flock -n "$GRM_DEVICE_LOCK" true
}

@test "symlinked device locks share resolved holder metadata with status and watchdog" {
  resolved_lock=$BATS_TEST_TMPDIR/resolved/device.lock
  ln -s "$resolved_lock" "$GRM_DEVICE_LOCK"
  mkfifo "$BATS_TEST_TMPDIR/finish"
  export GRM_SYSTEMCTL=true GITHUB_REPOSITORY=org/repo-a
  start_lock
  [ -s "$resolved_lock.holder" ]
  [ ! -e "$GRM_DEVICE_LOCK.holder" ]
  run "$GRM_ROOT/bin/grm-status"
  [ "$status" -eq 0 ]
  [[ $output == *'lock: held'* && $output == *'recorded holder: org/repo-a '* ]]
  run "$GRM_ROOT/bin/stale-lock-watchdog" --min-age 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo finish > "$BATS_TEST_TMPDIR/finish"
  wait "$wrapper"
  [ ! -e "$resolved_lock.holder" ]
  flock -n "$resolved_lock" true
}
