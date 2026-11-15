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
