#!/usr/bin/env bats
load helpers

fake_load() {
  export GRM_PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$GRM_PROC"
  printf '%s 0 0 1/1 1\n' "$1" > "$GRM_PROC/loadavg"
  printf 'MemAvailable: %s kB\n' "$2" > "$GRM_PROC/meminfo"
}

@test "load wait passes immediately under both limits" {
  fake_load 0.5 4194304
  run "$GRM_ROOT/bin/wait-for-load" --max-load 1 --min-mem-mb 1024 --interval 0
  [ "$status" -eq 0 ]
}

@test "load wait observes changing files" {
  fake_load 8 0
  (sleep 0.15; printf '0.5 0 0\n' > "$GRM_PROC/loadavg"; printf 'MemAvailable: 4194304 kB\n' > "$GRM_PROC/meminfo") &
  processes+=("$!")
  run "$GRM_ROOT/bin/wait-for-load" --max-load 1 --min-mem-mb 1024 --timeout 3 --interval 0.02
  [ "$status" -eq 0 ]
  [[ $output != *'::warning::'* ]]
}

@test "timeout can proceed with warning or fail" {
  fake_load 1 4194304
  run "$GRM_ROOT/bin/wait-for-load" --max-load 1 --timeout 0 --interval 0
  [ "$status" -eq 0 ]
  [[ $output == *'::warning::'* ]]
  fake_load 0 0
  run "$GRM_ROOT/bin/wait-for-load" --timeout 0 --on-timeout fail --interval 0
  [ "$status" -eq 1 ]
}

@test "missing metrics do not count as an idle machine" {
  export GRM_PROC="$BATS_TEST_TMPDIR/missing"
  run "$GRM_ROOT/bin/wait-for-load" --timeout 0 --on-timeout fail
  [ "$status" -eq 1 ]
  run "$GRM_ROOT/bin/wait-for-load" --min-mem-mb invalid
  [ "$status" -eq 2 ]
}
