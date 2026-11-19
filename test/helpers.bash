export BATS_TEST_TIMEOUT=20

setup() {
  export GRM_ROOT="$BATS_TEST_DIRNAME/.."
  export GRM_CONFIG=/dev/null GRM_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export GRM_RUNNERS_DIR="$BATS_TEST_TMPDIR/runners"
  export GRM_SYSTEMD_USER_DIR="$BATS_TEST_TMPDIR/units"
  export GRM_SLOTS_POLL=0.05 GRM_SLOTS_MAX_WAIT=5 GRM_SLOTS_CAPACITY=4
  export GRM_DEVICE_LOCK="$BATS_TEST_TMPDIR/device.lock"
  export GRM_DEVICE_LOCK_GRACE=1
  export GRM_LOAD_TIMEOUT=3
  # The suite itself runs in Actions jobs; their variables must not reach the hooks.
  unset "${!GITHUB_@}" RUNNER_NAME
  processes=()
}

teardown() {
  local process
  for process in "${processes[@]}"; do
    stop_tree "$process"
    wait "$process" 2>/dev/null || true
  done
}

stop_tree() {
  local process=$1 descendant
  local -a descendants=()
  if [[ -r /proc/$process/task/$process/children ]]; then
    read -r -a descendants < "/proc/$process/task/$process/children" || true
  fi
  for descendant in "${descendants[@]}"; do stop_tree "$descendant"; done
  kill -KILL "$process" 2>/dev/null || true
}

start_holder() {
  sleep 300 &
  holder=$!
  processes+=("$holder")
}

wait_for() {
  local attempt
  for ((attempt=0; attempt<200; attempt++)); do
    if "$@"; then return 0; fi
    sleep 0.025
  done
  return 1
}

has_record() {
  [[ -f $GRM_STATE_DIR/slots/state ]] &&
    awk -v kind="$1" -v holder="$2" '$1 == kind && $3 == holder {found=1} END {exit !found}' "$GRM_STATE_DIR/slots/state"
}

acquire_background() {
  "$GRM_ROOT/bin/job-slots" acquire --holder "$1" --units "$2" >"$BATS_TEST_TMPDIR/acquire-$1" 2>&1 &
  acquirer=$!
  processes+=("$acquirer")
}

find_lock_holders_for() {
  # shellcheck source=lib/common.sh
  (source "$GRM_ROOT/lib/common.sh"; find_lock_holders "$1")
}
