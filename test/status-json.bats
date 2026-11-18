#!/usr/bin/env bats
load helpers

# Evaluate a Python expression against the parsed JSON document in $output.
json() {
  command -v python3 > /dev/null || skip 'python3 is needed to parse JSON in tests'
  python3 -c 'import json, sys; document = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$output" "$1"
}

# Every key path in a document, with list items collapsed: the shape of the schema.
key_paths() {
  python3 -c '
import json, sys
def walk(node, path):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from walk(value, path + "." + key)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item, path + "[]")
    else:
        yield path
print("\n".join(sorted(set(walk(json.load(sys.stdin), "")))))'
}

stub_systemctl() {
  export GRM_SYSTEMCTL="$BATS_TEST_TMPDIR/systemctl"
  cat > "$GRM_SYSTEMCTL" <<'SCRIPT'
#!/usr/bin/env bash
if [[ $1 == is-active && $2 == grm-runner-repo-a.service ]]; then echo active; exit 0; fi
echo inactive; exit 3
SCRIPT
  chmod +x "$GRM_SYSTEMCTL"
}

write_config() {
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config.env"
  cat > "$GRM_CONFIG" <<'CONFIG'
GRM_RUNNERS=(
  "repo-a org/repo-a 3 self-hosted,linux,emulator"
  "repo-b org/repo-b 1"
)
CONFIG
}

fake_proc() {
  export GRM_PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$GRM_PROC"
  printf '1.50 0 0\n' > "$GRM_PROC/loadavg"
  printf 'MemAvailable: 4194304 kB\n' > "$GRM_PROC/meminfo"
}

@test "json status on an unused installation is valid, versioned and creates nothing" {
  export GRM_SYSTEMCTL=true GRM_MAX_LOAD=6
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["schema"]')" = 1 ]
  [ "$(json 'document["slots"]["capacity"], document["slots"]["used"], document["slots"]["records"]')" = "(4, 0, [])" ]
  [ "$(json 'document["device_lock"]["state"], document["device_lock"]["holder"]')" = "('absent', None)" ]
  [ "$(json 'document["runners"], document["events"]')" = "([], [])" ]
  [ "$(json 'document["host"]["max_load"]')" = 6 ]
  [ ! -e "$GRM_STATE_DIR" ]
  [ ! -e "$GRM_DEVICE_LOCK" ]
}

@test "json status reports runners with unit state and busy worker" {
  stub_systemctl; write_config
  mkdir -p "$GRM_RUNNERS_DIR/repo-a/bin"
  # A copy of bash blocked on a fifo: a renamed coreutils binary refuses to
  # run where coreutils is one multi-call executable.
  cp "$(command -v bash)" "$GRM_RUNNERS_DIR/repo-a/bin/Fake.Worker"
  mkfifo "$BATS_TEST_TMPDIR/idle"
  "$GRM_RUNNERS_DIR/repo-a/bin/Fake.Worker" -c 'exec 3<> "$1"; read -r -u 3 _' _ "$BATS_TEST_TMPDIR/idle" &
  worker=$!; processes+=("$worker")
  export GRM_WORKER_COMM=Fake.Worker
  wait_for grep -qx Fake.Worker "/proc/$worker/comm"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json '[(r["name"], r["repository"], r["units"], r["labels"], r["unit"], r["unit_state"]) for r in document["runners"]]')" = \
    "[('repo-a', 'org/repo-a', 3, 'self-hosted,linux,emulator', 'grm-runner-repo-a.service', 'active'), ('repo-b', 'org/repo-b', 1, '', 'grm-runner-repo-b.service', 'inactive')]" ]
  [ "$(json '[r["worker_pid"] for r in document["runners"]]')" = "[$worker, None]" ]
}

@test "json status lists every busy worker, on a configured runner or not" {
  stub_systemctl; write_config
  export GRM_WORKER_COMM=Fake.Worker
  mkfifo "$BATS_TEST_TMPDIR/idle"
  mkdir -p "$GRM_RUNNERS_DIR/repo-a" "$BATS_TEST_TMPDIR/elsewhere/other-runner"
  listed=$(readlink -f "$GRM_RUNNERS_DIR/repo-a")
  unlisted=$(readlink -f "$BATS_TEST_TMPDIR/elsewhere/other-runner")
  for directory in "$listed" "$unlisted"; do
    mkdir -p "$directory/bin"
    cp "$(command -v bash)" "$directory/bin/Fake.Worker"
    "$directory/bin/Fake.Worker" -c 'exec 3<> "$1"; read -r -u 3 _' _ "$BATS_TEST_TMPDIR/idle" &
    processes+=("$!")
    wait_for grep -qx Fake.Worker "/proc/$!/comm"
  done
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'sorted((w["directory"], w["pid"]) for w in document["workers"])')" = \
    "[('$unlisted', ${processes[1]}), ('$listed', ${processes[0]})]" ]
  [ "$(json '[r["worker_pid"] for r in document["runners"]]')" = "[${processes[0]}, None]" ]
}

@test "json status lists slot records with kind, units, label and since, without writing" {
  export GRM_SYSTEMCTL=true
  start_holder; first=$holder
  start_holder; second=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$first" --units 3 --label org/repo-a
  acquire_background "$second" 2
  wait_for has_record queued "$second"
  cp "$GRM_STATE_DIR/slots/state" "$BATS_TEST_TMPDIR/before"
  now=$(date +%s)
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["slots"]["used"]')" = 3 ]
  [ "$(json '[(r["kind"], r["holder_pid"], r["units"], r["label"], r["unparking"]) for r in document["slots"]["records"]]')" = \
    "[('holding', $first, 3, 'org/repo-a', False), ('queued', $second, 2, 'job', False)]" ]
  [ "$(json "all(abs(r['since'] - $now) < 20 for r in document['slots']['records'])")" = True ]
  cmp "$BATS_TEST_TMPDIR/before" "$GRM_STATE_DIR/slots/state"
}

@test "json status shows the device holder and that it is alive" {
  export GRM_SYSTEMCTL=true
  GITHUB_REPOSITORY=org/repo-a GITHUB_RUN_ID=42 GITHUB_JOB=e2e "$GRM_ROOT/bin/with-device-lock" -- sleep 300 > /dev/null 2>&1 &
  wrapper=$!; processes+=("$wrapper")
  wait_for test -s "$GRM_DEVICE_LOCK.holder"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["device_lock"]["state"]')" = held ]
  [ "$(json '[document["device_lock"]["holder"][k] for k in ("repository", "run_id", "job", "pid", "alive")]')" = "['org/repo-a', '42', 'e2e', $wrapper, True]" ]
  [ "$(json 'document["device_lock"]["watchdog"]["stale"]')" = "[]" ]
  kill -TERM "$wrapper"; wait "$wrapper" || true
}

@test "json status reports stale lock holders and never signals them, even in kill mode" {
  export GRM_SYSTEMCTL=true GRM_WATCHDOG_MIN_AGE=0 GRM_WATCHDOG_KILL=1 GRM_WATCHDOG_KILL_ALLOW=sleep
  bash -c 'exec 17>"$1"; flock 17; sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/leaked"
  leaked=$(<"$BATS_TEST_TMPDIR/leaked"); processes+=("$leaked")
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json '[(s["pid"], s["fd"], s["command"]) for s in document["device_lock"]["watchdog"]["stale"]]')" = "[($leaked, 17, 'sleep')]" ]
  [ "$(json 'document["device_lock"]["watchdog"]["kill"], document["device_lock"]["holder"]')" = "(True, None)" ]
  kill -0 "$leaked"
}

@test "json status includes load, memory and thresholds, and nulls when metrics are missing" {
  export GRM_SYSTEMCTL=true GRM_MAX_LOAD=6 GRM_MIN_MEM_MB=2048
  fake_proc
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$(json '[document["host"][k] for k in ("load_1m", "max_load", "memory_available_mb", "min_memory_mb")]')" = "[1.5, 6, 4096, 2048]" ]
  rm "$GRM_PROC/loadavg"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["host"]["load_1m"], document["host"]["memory_available_mb"]')" = "(None, None)" ]
}

@test "json status carries recent events, escaped, newest last and capped at fifty" {
  export GRM_SYSTEMCTL=true
  mkdir -p "$GRM_STATE_DIR"
  : > "$GRM_STATE_DIR/events.lock"
  for number in $(seq 1 60); do printf '%s admit org/repo-a entry %s\n' "$((1700000000 + number))" "$number"; done > "$GRM_STATE_DIR/events.log"
  printf '1700000061 reap org/"quoted"\\name tab\there caf\xc3\xa9\n' >> "$GRM_STATE_DIR/events.log"
  printf 'not-a-time broken line\n' >> "$GRM_STATE_DIR/events.log"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'len(document["events"]), document["events"][0]["detail"]')" = "(49, 'entry 13')" ]
  [ "$(json 'document["events"][-1]["subject"]')" = 'org/"quoted"\name' ]
  [ "$(json 'document["events"][-1]["detail"]')" = 'tab?here caf??' ]
}

@test "the bundled demo fixture has exactly the shape of real json status" {
  command -v python3 > /dev/null || skip 'python3 is needed to parse JSON in tests'
  stub_systemctl; write_config; fake_proc
  export GRM_WATCHDOG_MIN_AGE=0
  start_holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$holder" --units 1 --label org/repo-a
  GITHUB_REPOSITORY=org/repo-a "$GRM_ROOT/bin/with-device-lock" -- sleep 300 > /dev/null 2>&1 &
  wrapper=$!; processes+=("$wrapper")
  wait_for test -s "$GRM_DEVICE_LOCK.holder"
  export GRM_WORKER_COMM=Fake.Worker
  mkdir -p "$GRM_RUNNERS_DIR/repo-a/bin"
  cp "$(command -v bash)" "$GRM_RUNNERS_DIR/repo-a/bin/Fake.Worker"
  mkfifo "$BATS_TEST_TMPDIR/idle"
  "$GRM_RUNNERS_DIR/repo-a/bin/Fake.Worker" -c 'exec 3<> "$1"; read -r -u 3 _' _ "$BATS_TEST_TMPDIR/idle" &
  processes+=("$!")
  wait_for grep -qx Fake.Worker "/proc/$!/comm"
  bash -c 'exec 17>"$1"; sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/leaked"
  processes+=("$(<"$BATS_TEST_TMPDIR/leaked")")
  "$GRM_ROOT/bin/grm-status" --json | key_paths > "$BATS_TEST_TMPDIR/real"
  key_paths < "$GRM_ROOT/dashboard/priv/demo/status.json" > "$BATS_TEST_TMPDIR/demo"
  kill -TERM "$wrapper"; wait "$wrapper" || true
  # The demo has no stale holder; real output here may. Compare the rest.
  diff <(grep -v 'watchdog.stale' "$BATS_TEST_TMPDIR/real") <(grep -v 'watchdog.stale' "$BATS_TEST_TMPDIR/demo")
}

@test "status rejects unknown arguments" {
  run "$GRM_ROOT/bin/grm-status" --yaml
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --json extra
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --watch soon
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --watch 0
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --watch 0.0
  [ "$status" -eq 2 ]
}

@test "json status stays valid when a configured number has leading zeros" {
  export GRM_SYSTEMCTL=true GRM_MAX_LOAD=08 GRM_MIN_MEM_MB=0512
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["host"]["max_load"], document["host"]["min_memory_mb"]')" = "(None, None)" ]
}

@test "watch repeats the text view until stopped" {
  export GRM_SYSTEMCTL=true
  run timeout 1 "$GRM_ROOT/bin/grm-status" --watch 0.2
  [ "$status" -eq 124 ]
  [ "$(grep -c 'Job slots' <<< "$output")" -ge 2 ]
}

@test "json status skips events, without waiting, while the event log stays locked" {
  mkdir -p "$GRM_STATE_DIR"
  printf '1700000001 admit org/repo-a entry\n' > "$GRM_STATE_DIR/events.log"
  : > "$GRM_STATE_DIR/events.lock"
  flock "$GRM_STATE_DIR/events.lock" sleep 300 < /dev/null > /dev/null 2>&1 3>&- &
  processes+=("$!")
  wait_for test -n "$(find_lock_holders_for "$GRM_STATE_DIR/events.lock")"
  run timeout 10 "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["events"]')" = '[]' ]
}

@test "json status fails, rather than show an empty gate, while the slot lock stays held" {
  mkdir -p "$GRM_STATE_DIR/slots"
  : > "$GRM_STATE_DIR/slots/lock"
  flock "$GRM_STATE_DIR/slots/lock" sleep 300 < /dev/null > /dev/null 2>&1 3>&- &
  processes+=("$!")
  wait_for test -n "$(find_lock_holders_for "$GRM_STATE_DIR/slots/lock")"
  GRM_LOCK_WAIT=1 run timeout 10 "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 75 ]
  [[ $output != *'"records"'* ]]
}
