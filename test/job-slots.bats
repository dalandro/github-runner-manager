#!/usr/bin/env bats
load helpers

@test "weighted slots fill capacity and release idempotently" {
  start_holder; first=$holder
  start_holder; second=$holder
  start_holder; third=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 2
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 2
  acquire_background "$third" 1
  wait_for has_record queued "$third"
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 4'* ]]
  "$GRM_ROOT/bin/job-slots" release --holder "$first"
  "$GRM_ROOT/bin/job-slots" release --holder "$first"
  wait_for has_record holding "$third"
}

@test "six concurrent acquirers never exceed capacity and all progress" {
  holders=()
  acquirers=()
  for number in {1..6}; do
    start_holder; holders+=("$holder")
    acquire_background "$holder" 1
    acquirers+=("$acquirer")
  done
  admitted=0
  for number in {1..100}; do
    run "$GRM_ROOT/bin/job-slots" status --raw
    [ "$status" -eq 0 ]
    used=$(awk '$1 == "holding" {sum += $7} END {print sum+0}' <<< "$output")
    [ "$used" -le 4 ]
    while read -r kind _ process _; do
      if [[ $kind == holding ]]; then
        "$GRM_ROOT/bin/job-slots" release --holder "$process"
        admitted=$((admitted + 1))
      fi
    done <<< "$output"
    if ((admitted == 6)); then break; fi
    sleep 0.025
  done
  [ "$admitted" -eq 6 ]
  for acquirer in "${acquirers[@]}"; do wait "$acquirer"; done
  for holder in "${holders[@]}"; do
    ! grep -q '::warning::' "$BATS_TEST_TMPDIR/acquire-$holder"
  done
}

@test "FIFO head blocks a smaller arrival" {
  start_holder; first=$holder
  start_holder; second=$holder
  start_holder; third=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 3
  acquire_background "$second" 2
  wait_for has_record queued "$second"
  acquire_background "$third" 1
  wait_for has_record queued "$third"
  ! has_record holding "$third"
  "$GRM_ROOT/bin/job-slots" release --holder "$first"
  wait_for has_record holding "$second"
  wait_for has_record holding "$third"
}

@test "dead holders and mismatched start times are reaped" {
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4
  kill "$first"; wait "$first" || true
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 4
  ! has_record holding "$first"
  "$GRM_ROOT/bin/job-slots" release --holder "$second"
  printf 'holding 100 %s 0 0 0 4 stale\n' "$second" >> "$GRM_STATE_DIR/slots/state"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 1
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 1'* ]]
}

@test "killed waiters cannot block later arrivals" {
  start_holder; first=$holder
  start_holder; second=$holder
  start_holder; third=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4
  acquire_background "$second" 4
  waiter=$acquirer
  wait_for has_record queued "$second"
  kill -KILL "$waiter"; wait "$waiter" || true
  acquire_background "$third" 1
  wait_for has_record queued "$third"
  "$GRM_ROOT/bin/job-slots" release --holder "$first"
  wait_for has_record holding "$third"
  ! has_record queued "$second"
}

unpark_is_waiting() {
  "$GRM_ROOT/bin/job-slots" status --raw |
    awk -v holder="$1" '$1 == "parked" && $3 == holder && $5 != 0 {found=1} END {exit !found}'
}

@test "park returns units and unpark has priority over queued requests" {
  start_holder; parked_holder=$holder
  start_holder; active_holder=$holder
  start_holder; blocking_holder=$holder
  start_holder; queued_holder=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$parked_holder" --units 3
  "$GRM_ROOT/bin/job-slots" park --holder "$parked_holder"
  "$GRM_ROOT/bin/job-slots" acquire --holder "$active_holder" --units 1
  "$GRM_ROOT/bin/job-slots" acquire --holder "$blocking_holder" --units 2
  acquire_background "$queued_holder" 2
  wait_for has_record queued "$queued_holder"
  "$GRM_ROOT/bin/job-slots" unpark --holder "$parked_holder" > "$BATS_TEST_TMPDIR/unpark" 2>&1 &
  processes+=("$!")
  wait_for unpark_is_waiting "$parked_holder"
  "$GRM_ROOT/bin/job-slots" release --holder "$active_holder"
  # Two units are free: the queued request fits, but the three-unit unpark does not.
  for attempt in {1..12}; do
    run "$GRM_ROOT/bin/job-slots" status --raw
    [ "$status" -eq 0 ]
    awk -v holder="$queued_holder" '$1 == "queued" && $3 == holder {found=1} END {exit !found}' <<< "$output"
    awk -v holder="$parked_holder" '$1 == "parked" && $3 == holder && $5 != 0 {found=1} END {exit !found}' <<< "$output"
    sleep 0.05
  done
  "$GRM_ROOT/bin/job-slots" release --holder "$blocking_holder"
  wait_for has_record holding "$parked_holder"
  has_record queued "$queued_holder"
  "$GRM_ROOT/bin/job-slots" release --holder "$parked_holder"
  wait_for has_record holding "$queued_holder"
}

@test "max wait escapes with warning and records overcommit" {
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4
  run env GRM_SLOTS_MAX_WAIT=0 "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 2
  [ "$status" -eq 0 ]
  [[ $output == *'::warning::'* ]]
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 6'* ]]
}

@test "oversize requests enter alone and status reaps without writing" {
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 5
  cp "$GRM_STATE_DIR/slots/state" "$BATS_TEST_TMPDIR/before"
  kill "$holder"; wait "$holder" || true
  run "$GRM_ROOT/bin/job-slots" status --raw
  [ "$status" -eq 0 ]
  [[ $output != *holding* ]]
  cmp "$GRM_STATE_DIR/slots/state" "$BATS_TEST_TMPDIR/before"
}

@test "parking and unparking an ungated holder are harmless" {
  start_holder
  "$GRM_ROOT/bin/job-slots" park --holder "$holder"
  "$GRM_ROOT/bin/job-slots" unpark --holder "$holder"
  run "$GRM_ROOT/bin/job-slots" acquire --units 0
  [ "$status" -eq 2 ]
}

@test "release and parking stay idempotent after a holder exits" {
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  kill "$holder"; wait "$holder" || true
  "$GRM_ROOT/bin/job-slots" release --holder "$holder"
  "$GRM_ROOT/bin/job-slots" park --holder "$holder"
  "$GRM_ROOT/bin/job-slots" unpark --holder "$holder"
}

@test "invalid numeric configuration returns usage error" {
  start_holder
  run env GRM_SLOTS_CAPACITY=08 "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  [ "$status" -eq 2 ]
}

@test "asking for parked units back restarts the record's clock" {
  start_holder; first=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 3
  "$GRM_ROOT/bin/job-slots" park --holder "$first"
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 3
  parked_since=$("$GRM_ROOT/bin/job-slots" status --raw | awk -v holder="$first" '$3 == holder {print $9}')
  sleep 1.1
  "$GRM_ROOT/bin/job-slots" unpark --holder "$first" > /dev/null 2>&1 &
  processes+=("$!")
  is_unparking() {
    local since
    since=$("$GRM_ROOT/bin/job-slots" status --raw | awk -v holder="$first" '$1 == "parked" && $3 == holder {print $9}')
    [[ -n $since ]] && ((since > parked_since))
  }
  wait_for is_unparking
}

# A state record for a live holder with one field replaced, as anything that can
# write the shared state file could leave it. Bash evaluates a variable's value
# in arithmetic, so a field such as next[$(command)] there would run the command.
write_poisoned_state() { # <field number, 1-9, or "next"> <value>
  local start
  start=$(source "$GRM_ROOT/lib/common.sh"; get_start_time "$holder")
  mkdir -p "$GRM_STATE_DIR/slots"
  : > "$GRM_STATE_DIR/slots/lock"
  awk -v field="$1" -v value="$2" -v holder="$holder" -v start="$start" 'BEGIN {
    split("holding 1 " holder " " start " 0 0 1 org/repo-a 1700000000", record, " ")
    next_ticket = 2
    if (field == "next") next_ticket = value; else record[field] = value
    print "next " next_ticket
    print record[1], record[2], record[3], record[4], record[5], record[6], record[7], record[8], record[9]
  }' > "$GRM_STATE_DIR/slots/state"
}

@test "state fields that are not plain numbers are never evaluated" {
  marker=$BATS_TEST_TMPDIR/executed
  payload='next[$(touch${IFS}'"$marker"')]'
  export GRM_SYSTEMCTL=true
  start_holder
  start_holder; second=$holder
  for field in next 2 3 4 5 6 7 9; do
    holder=${processes[0]}
    write_poisoned_state "$field" "$payload"
    run "$GRM_ROOT/bin/job-slots" status
    [ ! -e "$marker" ]
    [ "$status" -eq 0 ]
    run "$GRM_ROOT/bin/job-slots" status --raw
    [ ! -e "$marker" ]
    [ "$status" -eq 0 ]
    [[ $output != *'$('* ]]
    run "$GRM_ROOT/bin/grm-status" --json
    [ ! -e "$marker" ]
    [ "$status" -eq 0 ]
    run "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 3
    [ ! -e "$marker" ]
    [ "$status" -eq 0 ]
    [[ $(<"$GRM_STATE_DIR/slots/state") != *'$('* ]]
    "$GRM_ROOT/bin/job-slots" release --holder "$second"
  done
}

@test "a malformed record is dropped as corrupt and logged by the next writer" {
  start_holder; first=$holder
  start_holder; second=$holder
  for value in 08 -1 '1+1' 0 ''; do
    holder=$first
    write_poisoned_state 7 "$value"
    run "$GRM_ROOT/bin/job-slots" status
    [[ $output == *'used 0'* ]]
  done
  # An extra field, a label outside the label alphabet and an unknown kind.
  holder=$first
  write_poisoned_state 9 '1700000000 extra'
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 0'* ]]
  write_poisoned_state 8 'org/repo;a'
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 0'* ]]
  write_poisoned_state 1 'holdin'
  run "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 4
  [ "$status" -eq 0 ]
  [[ $output == *'::warning::'*'corrupt'* ]]
  grep -q ' corrupt ' "$GRM_STATE_DIR/events.log"
  ! grep -qw holdin "$GRM_STATE_DIR/slots/state"
}

@test "a well-formed record with an underscore label and no since field is kept" {
  start_holder
  write_poisoned_state 8 org/my_repo
  sed -i 's/ 1700000000$//' "$GRM_STATE_DIR/slots/state"
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 1'* && $output == *'org/my_repo 0'* ]]
}

@test "a corrupt next ticket cannot hand out a ticket already in use" {
  start_holder; first=$holder
  start_holder; second=$holder
  holder=$first
  write_poisoned_state next 'x'
  acquire_background "$second" 4
  wait_for has_record queued "$second"
  run "$GRM_ROOT/bin/job-slots" status --raw
  [ "$(awk '$1 == "queued" {print $2}' <<< "$output")" = 2 ]
  "$GRM_ROOT/bin/job-slots" release --holder "$first"
  wait_for has_record holding "$second"
}

@test "a waiting job's log counts the other jobs and never names them" {
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 4 --label org/other-repo
  "$GRM_ROOT/bin/job-slots" acquire --holder "$second" --units 1 --label org/my-repo > "$BATS_TEST_TMPDIR/waiting" 2>&1 &
  processes+=("$!")
  wait_for grep -q 'waiting' "$BATS_TEST_TMPDIR/waiting"
  grep -q 'used 4/4; 1 other job' "$BATS_TEST_TMPDIR/waiting"
  ! grep -q 'other-repo' "$BATS_TEST_TMPDIR/waiting"
}

@test "a job gives up on a slot lock another process never releases" {
  start_holder
  mkdir -p "$GRM_STATE_DIR/slots"
  : > "$GRM_STATE_DIR/slots/lock"
  flock "$GRM_STATE_DIR/slots/lock" sleep 300 < /dev/null > /dev/null 2>&1 3>&- &
  processes+=("$!")
  wait_for test -n "$(find_lock_holders_for "$GRM_STATE_DIR/slots/lock")"
  for command in acquire release status; do
    SECONDS=0
    GRM_LOCK_WAIT=1 run "$GRM_ROOT/bin/job-slots" "$command" --holder "$holder"
    [ "$status" -eq 75 ]
    [[ $output == *'::error::'*'locked'* ]]
    ((SECONDS < 5))
  done
  GRM_LOCK_WAIT=soon run "$GRM_ROOT/bin/job-slots" status
  [ "$status" -eq 2 ]
}

@test "ticket zero is corrupt, and the lock wait must be positive" {
  start_holder
  write_poisoned_state 2 0
  run "$GRM_ROOT/bin/job-slots" status
  [[ $output == *'used 0'* ]]
  write_poisoned_state next 0
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1
  awk -v holder="$holder" '$3 == holder && $2 > 1 {found=1} END {exit !found}' "$GRM_STATE_DIR/slots/state"
  GRM_LOCK_WAIT=0 run "$GRM_ROOT/bin/job-slots" status
  [ "$status" -eq 2 ]
}
