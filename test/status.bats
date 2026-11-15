#!/usr/bin/env bats
load helpers

@test "status shows units slots lock and load without changing state" {
  export GRM_SYSTEMCTL="$BATS_TEST_TMPDIR/systemctl"
  cat > "$GRM_SYSTEMCTL" <<'SCRIPT'
#!/usr/bin/env bash
printf 'unit overview: %s\n' "$*"
SCRIPT
  chmod +x "$GRM_SYSTEMCTL"
  export GRM_PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$GRM_PROC"
  printf '0.25 0 0\n' > "$GRM_PROC/loadavg"
  printf 'MemAvailable: 4194304 kB\n' > "$GRM_PROC/meminfo"
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 2
  cp "$GRM_STATE_DIR/slots/state" "$BATS_TEST_TMPDIR/before"
  printf 'org/repo-a unknown job 0 0 0\n' > "$GRM_DEVICE_LOCK.holder"
  : > "$GRM_DEVICE_LOCK"
  run "$GRM_ROOT/bin/grm-status"
  [ "$status" -eq 0 ]
  [[ $output == *'list-units --all grm-runner-*'* ]]
  [[ $output == *'used 2'* && $output == *'lock: free'* ]]
  [[ $output == *'0.25'* && $output == *'4096 MB'* ]]
  cmp "$BATS_TEST_TMPDIR/before" "$GRM_STATE_DIR/slots/state"
  flock -n "$GRM_DEVICE_LOCK" true
}

@test "status on an unused installation creates no state or lock" {
  export GRM_SYSTEMCTL=true
  run "$GRM_ROOT/bin/grm-status"
  [ "$status" -eq 0 ]
  [[ $output == *'used 0'* && $output == *'lock: absent'* ]]
  [ ! -e "$GRM_STATE_DIR" ]
  [ ! -e "$GRM_DEVICE_LOCK" ]
}

@test "status reports held and free without probing the device with flock" {
  export GRM_SYSTEMCTL=true
  export REAL_FLOCK
  REAL_FLOCK=$(command -v flock)
  mkdir -p "$BATS_TEST_TMPDIR/stubs"
  cat > "$BATS_TEST_TMPDIR/stubs/flock" <<'SCRIPT'
#!/usr/bin/env bash
printf 'called\n' >> "$GRM_DEVICE_LOCK.probes"
exec "$REAL_FLOCK" "$@"
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/stubs/flock"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
  exec {device_fd}>"$GRM_DEVICE_LOCK"
  "$REAL_FLOCK" -n "$device_fd"
  run "$GRM_ROOT/bin/grm-status"
  [ "$status" -eq 0 ]
  [[ $output == *'lock: held'* ]]
  "$REAL_FLOCK" -u "$device_fd"
  run "$GRM_ROOT/bin/grm-status"
  [ "$status" -eq 0 ]
  [[ $output == *'lock: free'* ]]
  [ ! -e "$GRM_DEVICE_LOCK.probes" ]
  "$REAL_FLOCK" -n "$GRM_DEVICE_LOCK" true
  exec {device_fd}>&-
}
