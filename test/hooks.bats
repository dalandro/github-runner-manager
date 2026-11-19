#!/usr/bin/env bats
load helpers

@test "hooks require a worker or explicit holder and use configured units" {
  GRM_WORKER_COMM=no-such-worker run "$GRM_ROOT/hooks/job-started.sh"
  [ "$status" -eq 2 ]
  [[ $output == *'job hook'* ]]
  start_holder
  export GRM_JOB_UNITS=2 GITHUB_REPOSITORY=org/repo-a
  "$GRM_ROOT/hooks/job-started.sh" --holder "$holder"
  run "$GRM_ROOT/bin/job-slots" status --raw
  [[ $output == *'2 org/repo-a'* ]]
  "$GRM_ROOT/hooks/job-completed.sh" --holder "$holder"
  ! has_record holding "$holder"
}

@test "hooks resolve symlinks to the installation" {
  start_holder
  ln -s "$GRM_ROOT/hooks/job-started.sh" "$BATS_TEST_TMPDIR/start"
  GRM_JOB_UNITS=1 "$BATS_TEST_TMPDIR/start" --holder "$holder"
  has_record holding "$holder"
}

# Runs the start hook for $holder with the variables a pull request job sees.
start_pull_request_job() {
  GRM_JOB_UNITS=1 GITHUB_REPOSITORY=org/repo-a GITHUB_WORKFLOW='CI checks' GITHUB_JOB=test \
    GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=2 GITHUB_REF=refs/pull/7/merge GITHUB_HEAD_REF=feature/x \
    GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 GITHUB_EVENT_NAME=pull_request \
    GITHUB_ACTOR=dev-one RUNNER_NAME=repo-a-1 GITHUB_SERVER_URL=https://github.com \
    env "$@" "$GRM_ROOT/hooks/job-started.sh" --holder "$holder"
}

@test "the start hook records the job for the status views and completion removes it" {
  start_holder
  start_pull_request_job
  record=$GRM_STATE_DIR/jobs/$holder
  # shellcheck source=lib/common.sh
  source "$GRM_ROOT/lib/common.sh"
  [ "$(head -n 1 "$record")" = "start $(get_start_time "$holder")" ]
  [[ $(sed -n 's/^queued_at //p' "$record") =~ ^[0-9]+$ ]]
  [ "$(grep -v -e '^start ' -e '^queued_at ' "$record")" = "$(cat <<'RECORD'
repository org/repo-a
workflow CI checks
job test
run_id 1001
run_attempt 2
ref refs/pull/7/merge
head_ref feature/x
sha 0123456789abcdef0123456789abcdef01234567
event pull_request
actor dev-one
runner repo-a-1
server_url https://github.com
RECORD
)" ]
  has_record holding "$holder"
  "$GRM_ROOT/hooks/job-completed.sh" --holder "$holder"
  [ ! -e "$record" ]
  ! has_record holding "$holder"
}

@test "the start hook records only what the job has, on one line per field" {
  start_holder
  GRM_JOB_UNITS=1 GITHUB_REPOSITORY=org/repo-a GITHUB_WORKFLOW=$'two\nlines' "$GRM_ROOT/hooks/job-started.sh" --holder "$holder"
  [ "$(grep -v -e '^start ' -e '^queued_at ' "$GRM_STATE_DIR/jobs/$holder")" = $'repository org/repo-a\nworkflow two lines' ]
}

@test "the start hook takes the pull request number and title from the event payload" {
  command -v python3 > /dev/null || skip 'python3 reads the event payload'
  start_holder
  printf '{"number": 7, "pull_request": {"number": 7, "title": "Add \\"quoted\\" text\\nand more", "milestone": {"title": "not this"}}}' > "$BATS_TEST_TMPDIR/event.json"
  start_pull_request_job GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  grep -qx 'pull_request 7' "$GRM_STATE_DIR/jobs/$holder"
  grep -qx 'pull_request_title Add "quoted" text and more' "$GRM_STATE_DIR/jobs/$holder"
}

@test "a payload without a pull request, or not JSON at all, records neither and still admits" {
  start_holder; first=$holder
  printf '{"ref": "refs/heads/main", "pull_request": {"title": ["not", "text"]}}' > "$BATS_TEST_TMPDIR/push.json"
  start_pull_request_job GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/push.json"
  start_holder; second=$holder
  printf 'not json' > "$BATS_TEST_TMPDIR/broken.json"
  start_pull_request_job GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/broken.json"
  ! grep -q '^pull_request' "$GRM_STATE_DIR/jobs/$first" "$GRM_STATE_DIR/jobs/$second"
  has_record holding "$first"
  has_record holding "$second"
}

@test "a record left by a job whose completion hook never ran goes at the next start" {
  start_holder; gone=$holder
  start_pull_request_job
  kill "$gone"; wait "$gone" || true
  start_holder
  start_pull_request_job
  [ ! -e "$GRM_STATE_DIR/jobs/$gone" ]
  [ -f "$GRM_STATE_DIR/jobs/$holder" ]
}

@test "a job record that cannot be written does not stop the job" {
  start_holder
  mkdir -p "$GRM_STATE_DIR"
  : > "$GRM_STATE_DIR/jobs"
  start_pull_request_job
  has_record holding "$holder"
}
