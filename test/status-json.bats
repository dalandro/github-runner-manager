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

# An installation where every field of json status has a value: two runners
# (one busy), a slot holder whose job the hook recorded in full, the device
# lock held by a job, a stale lock holder, and their events. Demo names.
full_installation() {
  command -v python3 > /dev/null || skip 'python3 is needed to parse JSON in tests'
  fake_proc
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config.env" GRM_SYSTEMCTL=true GRM_WATCHDOG_MIN_AGE=0
  cat > "$GRM_CONFIG" <<'CONFIG'
GRM_RUNNERS=(
  "mobile-app org/mobile-app 3 self-hosted,linux,emulator"
  "web-app org/web-app 1 self-hosted,linux"
)
CONFIG
  printf '{"pull_request": {"number": 57, "title": "Keep drafts while offline"}}' > "$BATS_TEST_TMPDIR/event.json"
  start_holder
  GRM_JOB_UNITS=3 GITHUB_REPOSITORY=org/mobile-app GITHUB_WORKFLOW=Android GITHUB_JOB=e2e-android \
    GITHUB_RUN_ID=8123456789 GITHUB_RUN_ATTEMPT=1 GITHUB_REF=refs/pull/57/merge \
    GITHUB_HEAD_REF=feature/offline-drafts GITHUB_SHA=3f9a1c27d84be5a0c6f1e2d93b7a4c58e1d06b72 \
    GITHUB_EVENT_NAME=pull_request GITHUB_ACTOR=dev-alex RUNNER_NAME=mobile-app \
    GITHUB_SERVER_URL=https://github.example.com GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json" \
    "$GRM_ROOT/hooks/job-started.sh" --holder "$holder"
  # The lock as with-device-lock records it, held by a process that is not the
  # recorded holder: a stale holder beside a live one.
  start_holder
  printf 'org/mobile-app 8123456789 e2e-android %s %s %s\n' "$holder" \
    "$(bash -c 'source "$1/lib/common.sh"; get_start_time "$2"' _ "$GRM_ROOT" "$holder")" "$(date +%s)" > "$GRM_DEVICE_LOCK.holder"
  bash -c 'exec 17>"$1"; flock 17; sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$2"' _ "$GRM_DEVICE_LOCK" "$BATS_TEST_TMPDIR/leaked"
  processes+=("$(<"$BATS_TEST_TMPDIR/leaked")")
  printf '%s lock-acquire org/mobile-app job e2e-android\n' "$(date +%s)" >> "$GRM_STATE_DIR/events.log"
  printf '1767260000 %s org/mobile-app e2e-android Android\n' 1380 1512 1446 > "$GRM_STATE_DIR/durations.log"
  : > "$GRM_STATE_DIR/durations.lock"
  export GRM_WORKER_COMM=Fake.Worker
  mkdir -p "$GRM_RUNNERS_DIR/mobile-app/bin"
  cp "$(command -v bash)" "$GRM_RUNNERS_DIR/mobile-app/bin/Fake.Worker"
  mkfifo "$BATS_TEST_TMPDIR/idle"
  "$GRM_RUNNERS_DIR/mobile-app/bin/Fake.Worker" -c 'exec 3<> "$1"; read -r -u 3 _' _ "$BATS_TEST_TMPDIR/idle" &
  processes+=("$!")
  wait_for grep -qx Fake.Worker "/proc/$!/comm"
}

# Key paths as lib/public.sh names them: no leading dot, no list markers.
field_paths() {
  key_paths | sed -e 's/^[.]//' -e 's/\[\]//g'
}

@test "the bundled demo fixture has exactly the shape of real json status" {
  full_installation
  "$GRM_ROOT/bin/grm-status" --json | key_paths > "$BATS_TEST_TMPDIR/real"
  key_paths < "$GRM_ROOT/dashboard/priv/demo/status.json" > "$BATS_TEST_TMPDIR/demo"
  # The demo has no stale holder; real output here has one. Compare the rest.
  diff <(grep -v 'watchdog.stale' "$BATS_TEST_TMPDIR/real") <(grep -v 'watchdog.stale' "$BATS_TEST_TMPDIR/demo")
}

@test "every field of json status has a public class, and every class a field" {
  full_installation
  "$GRM_ROOT/bin/grm-status" --json | field_paths > "$BATS_TEST_TMPDIR/fields"
  # A new field fails here until lib/public.sh says what --public does with it.
  diff "$BATS_TEST_TMPDIR/fields" <(bash -c 'source "$1/lib/common.sh"; source "$1/lib/public.sh"; public_classes' _ "$GRM_ROOT" | cut -d' ' -f1 | LC_ALL=C sort)
}

@test "public json has the shape of json status and names nothing on this machine" {
  full_installation
  "$GRM_ROOT/bin/grm-status" --json | key_paths > "$BATS_TEST_TMPDIR/private"
  run "$GRM_ROOT/bin/grm-status" --json --public
  [ "$status" -eq 0 ]
  diff "$BATS_TEST_TMPDIR/private" <(key_paths <<< "$output")
  for private in mobile-app web-app org/ self-hosted grm-runner- Android e2e-android 8123456789 \
    refs/ feature/offline-drafts 3f9a1c2 dev-alex github.example.com 'Keep drafts' \
    "$BATS_TEST_TMPDIR" "$HOME"; do
    [[ $output != *"$private"* ]] || { echo "public json contains $private"; return 1; }
  done
  [ "$(json '[(r["name"], r["repository"], r["labels"], r["unit"]) for r in document["runners"]]')" = \
    "[('runner-1', 'repo-1', '', 'runner-1.service'), ('runner-2', 'repo-2', '', 'runner-2.service')]" ]
  [ "$(json '[w["directory"] for w in document["workers"]]')" = "['runner-1']" ]
  [ "$(json 'document["slots"]["records"][0]["label"], document["device_lock"]["holder"]["repository"]')" = "('repo-1', 'repo-1')" ]
  [ "$(json 'sorted({k: v for k, v in document["slots"]["records"][0]["job"].items() if v is not None})')" = "['queued_at', 'recent_durations', 'repository', 'runner']" ]
  [ "$(json 'document["slots"]["records"][0]["job"]["recent_durations"]')" = '[1380, 1512, 1446]' ]
  [ "$(json '[document["device_lock"]["holder"][k] for k in ("run_id", "job")]')" = "['', '']" ]
  [ "$(json '[e["detail"] for e in document["events"] if e["kind"] == "lock-acquire"]')" = "['']" ]
  [ "$(json '[e["detail"] for e in document["events"] if e["kind"] == "admit"][0].startswith("ticket ")')" = True ]
}

@test "public json replaces every value that is not kept, field by field" {
  full_installation
  "$GRM_ROOT/bin/grm-status" --json > "$BATS_TEST_TMPDIR/private.json"
  "$GRM_ROOT/bin/grm-status" --json --public > "$BATS_TEST_TMPDIR/public.json"
  bash -c 'source "$1/lib/common.sh"; source "$1/lib/public.sh"; public_classes' _ "$GRM_ROOT" > "$BATS_TEST_TMPDIR/classes"
  # Catches a field that has a class but whose value skips public_field: its
  # real value would reach the public copy unchanged. Events are kept by
  # public_subject and public_detail where they hold no names (other tests).
  run python3 -c '
import json, sys
private, public = (json.load(open(name)) for name in sys.argv[1:3])
classes = dict(line.split() for line in open(sys.argv[3]))
seen, leaked = set(), []
def walk(mine, theirs, path):
    if isinstance(mine, dict):
        for key in mine:
            walk(mine[key], theirs[key], path + [key])
    elif isinstance(mine, list):
        for item, other in zip(mine, theirs):
            walk(item, other, path)
    else:
        name = ".".join(path)
        if classes[name] == "keep" or name.startswith("events.") or mine in (None, ""):
            return
        seen.add(name)
        if theirs == mine:
            leaked.append(f"{name}: {mine!r}")
walk(private, public, [])
untested = sorted(name for name, kind in classes.items() if kind != "keep" and not name.startswith("events.") and name not in seen)
print("\n".join(leaked + [f"no value to test in {name}" for name in untested]))
' "$BATS_TEST_TMPDIR/private.json" "$BATS_TEST_TMPDIR/public.json" "$BATS_TEST_TMPDIR/classes"
  [ "$status" -eq 0 ]
  [ "$output" = '' ] || { echo "$output"; return 1; }
}

@test "GRM_RELAY_SHARE_DETAILS=1 sends names, job details and links, never paths, labels or the actor" {
  full_installation
  GRM_RELAY_SHARE_DETAILS=1 run "$GRM_ROOT/bin/grm-status" --json --public
  [ "$status" -eq 0 ]
  [ "$(json '[(r["name"], r["repository"], r["labels"]) for r in document["runners"]]')" = \
    "[('mobile-app', 'org/mobile-app', ''), ('web-app', 'org/web-app', '')]" ]
  [ "$(json '[w["directory"] for w in document["workers"]]')" = "['mobile-app']" ]
  [ "$(json '[document["slots"]["records"][0]["job"][k] for k in ("run_id", "pull_request", "pull_request_title", "server_url", "actor")]')" = \
    "['8123456789', 57, 'Keep drafts while offline', 'https://github.example.com', None]" ]
  [ "$(json '[e["detail"] for e in document["events"] if e["kind"] == "lock-acquire"]')" = "['job e2e-android']" ]
  [[ $output != *"$BATS_TEST_TMPDIR"* && $output != *dev-alex* ]]
}

@test "public json refuses to print a field that has no public class" {
  full_installation
  mkdir "$BATS_TEST_TMPDIR/copy"
  cp -r "$GRM_ROOT/bin" "$GRM_ROOT/lib" "$BATS_TEST_TMPDIR/copy"
  sed -i 's/ \[events.detail\]=numeric//' "$BATS_TEST_TMPDIR/copy/lib/public.sh"
  ! grep -q 'events.detail' "$BATS_TEST_TMPDIR/copy/lib/public.sh"
  run "$BATS_TEST_TMPDIR/copy/bin/grm-status" --json --public
  [ "$status" -eq 70 ]
  [[ $output == *'events.detail has no public class'* ]]
  [[ $output != *'"schema"'* ]]
}

@test "status rejects unknown arguments" {
  run "$GRM_ROOT/bin/grm-status" --yaml
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --json extra
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --public
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-status" --json --public extra
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

@test "json status gives each slot record its job, and nulls where the hooks recorded none" {
  export GRM_SYSTEMCTL=true
  start_holder; hooked=$holder
  GRM_JOB_UNITS=1 GITHUB_REPOSITORY=org/repo-a GITHUB_WORKFLOW='CI "checks"' GITHUB_JOB=test \
    GITHUB_RUN_ID=1001 GITHUB_RUN_ATTEMPT=2 GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=push \
    "$GRM_ROOT/hooks/job-started.sh" --holder "$hooked"
  start_holder; bare=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$bare" --units 1 --label org/repo-b
  start_holder; reused=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$reused" --units 1 --label org/repo-c
  printf 'start 1\nrepository org/someone-else\n' > "$GRM_STATE_DIR/jobs/$reused"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json '[(r["holder_pid"], r["job"]["repository"], r["job"]["workflow"], r["job"]["run_id"], r["job"]["run_attempt"], r["job"]["ref"], r["job"]["event"], r["job"]["head_ref"], r["job"]["pull_request"]) for r in document["slots"]["records"]]')" = \
    "[($hooked, 'org/repo-a', 'CI \"checks\"', '1001', 2, 'refs/heads/main', 'push', None, None), ($bare, None, None, None, None, None, None, None, None), ($reused, None, None, None, None, None, None, None, None)]" ]
  [ "$(json "abs(document['slots']['records'][0]['job']['queued_at'] - $(date +%s)) < 20")" = True ]
  # A number field that is not a whole number reads as unknown.
  sed -i 's/^run_attempt 2$/run_attempt 1.5/' "$GRM_STATE_DIR/jobs/$hooked"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json '[document["slots"]["records"][0]["job"][key] for key in ("run_attempt", "run_id")]')" = "[None, '1001']" ]
  [ "$(json 'sorted(document["slots"]["records"][1]["job"])')" = \
    "['actor', 'event', 'head_ref', 'job', 'pull_request', 'pull_request_title', 'queued_at', 'recent_durations', 'ref', 'repository', 'run_attempt', 'run_id', 'runner', 'server_url', 'sha', 'workflow']" ]
}

@test "json status gives each job the durations of the last ten runs of the same repository, job and workflow" {
  export GRM_SYSTEMCTL=true
  start_holder; hooked=$holder
  GRM_JOB_UNITS=1 GITHUB_REPOSITORY=org/repo-a GITHUB_WORKFLOW='CI checks' GITHUB_JOB=test \
    "$GRM_ROOT/hooks/job-started.sh" --holder "$hooked"
  start_holder; bare=$holder
  "$GRM_ROOT/bin/job-slots" acquire --holder "$bare" --units 1 --label org/repo-b
  mkdir -p "$GRM_STATE_DIR"
  {
    for seconds in 100 101 102 103 104 105 106 107 108 109 110 111; do
      printf '1767260000 %s org/repo-a test CI checks\n' "$seconds"
      printf '1767260000 9%s org/repo-b test CI checks\n' "$seconds"
      printf '1767260000 9%s org/repo-a lint CI checks\n' "$seconds"
      printf '1767260000 9%s org/repo-a test CI\n' "$seconds"
    done
    printf '1767260000 1.5 org/repo-a test CI checks\n'
    printf '1767260000 -3 org/repo-a test CI checks\n'
    printf 'not a line\n'
  } > "$GRM_STATE_DIR/durations.log"
  : > "$GRM_STATE_DIR/durations.lock"
  run "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json '[r["job"]["recent_durations"] for r in document["slots"]["records"]]')" = \
    "[[102, 103, 104, 105, 106, 107, 108, 109, 110, 111], []]" ]
}

@test "json status gives no durations, without waiting, while the duration log stays locked" {
  export GRM_SYSTEMCTL=true
  start_holder
  GRM_JOB_UNITS=1 GITHUB_REPOSITORY=org/repo-a GITHUB_WORKFLOW=CI GITHUB_JOB=test \
    "$GRM_ROOT/hooks/job-started.sh" --holder "$holder"
  printf '1767260000 100 org/repo-a test CI\n' > "$GRM_STATE_DIR/durations.log"
  : > "$GRM_STATE_DIR/durations.lock"
  flock "$GRM_STATE_DIR/durations.lock" sleep 300 < /dev/null > /dev/null 2>&1 3>&- &
  processes+=("$!")
  wait_for test -n "$(find_lock_holders_for "$GRM_STATE_DIR/durations.lock")"
  run timeout 10 "$GRM_ROOT/bin/grm-status" --json
  [ "$status" -eq 0 ]
  [ "$(json 'document["slots"]["records"][0]["job"]["recent_durations"]')" = '[]' ]
}
