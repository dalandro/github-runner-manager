#!/usr/bin/env bats
load helpers

@test "hooks require a worker or explicit holder and use configured units" {
  GRM_WORKER_COMM=no-such-worker run "$GRM_ROOT/hooks/job-started"
  [ "$status" -eq 2 ]
  [[ $output == *'job hook'* ]]
  start_holder
  export GRM_JOB_UNITS=2 GITHUB_REPOSITORY=org/repo-a
  "$GRM_ROOT/hooks/job-started" --holder "$holder"
  run "$GRM_ROOT/bin/job-slots" status --raw
  [[ $output == *'2 org/repo-a'* ]]
  "$GRM_ROOT/hooks/job-completed" --holder "$holder"
  ! has_record holding "$holder"
}

@test "hooks resolve symlinks to the installation" {
  start_holder
  ln -s "$GRM_ROOT/hooks/job-started" "$BATS_TEST_TMPDIR/start"
  GRM_JOB_UNITS=1 "$BATS_TEST_TMPDIR/start" --holder "$holder"
  has_record holding "$holder"
}
