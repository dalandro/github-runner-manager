#!/usr/bin/env bats
load helpers

# The pure parts of `grm-status --json --public` (lib/public.sh).
in_public() {
  # shellcheck source=lib/public.sh
  bash -c 'source "$GRM_ROOT/lib/common.sh"; source "$GRM_ROOT/lib/public.sh"; "$@"' _ "$@"
}

write_config() {
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config.env"
  cat > "$GRM_CONFIG" <<'CONFIG'
GRM_RUNNERS=(
  "mobile-app org/mobile-app 3"
  "tablet-app org/tablet-app 3"
  "web-app org/mobile-app 2"
)
CONFIG
}

@test "runners are aliased in config order, unknown ones as other" {
  write_config
  [ "$(in_public public_runner_alias mobile-app)" = runner-1 ]
  [ "$(in_public public_runner_alias web-app)" = runner-3 ]
  [ "$(in_public public_runner_alias somewhere-else)" = other ]
  [ "$(in_public public_runner_alias '')" = '' ]
}

@test "repositories are aliased in order of first use, unknown ones as other" {
  write_config
  [ "$(in_public public_repository_alias org/mobile-app)" = repo-1 ]
  [ "$(in_public public_repository_alias org/tablet-app)" = repo-2 ]
  [ "$(in_public public_repository_alias org/data-pipeline)" = other ]
  [ "$(in_public public_repository_alias job)" = other ]
  [ "$(in_public public_repository_alias '')" = '' ]
}

@test "an event subject is a repository alias, except a process or the slot file" {
  write_config
  [ "$(in_public public_subject admit org/tablet-app)" = repo-2 ]
  [ "$(in_public public_subject lock-acquire org/api)" = other ]
  [ "$(in_public public_subject stale adb)" = adb ]
  [ "$(in_public public_subject kill deploy-tablet-a)" = process ]
  [ "$(in_public public_subject corrupt slots)" = slots ]
  [ "$(in_public public_subject corrupt org/tablet-app)" = slots ]
}

@test "a process name passes only when it is a known device tool" {
  for name in adb emulator qemu-system-x86 qemu-system-aar; do
    [ "$(in_public public_process_alias "$name")" = "$name" ]
  done
  [ "$(in_public public_process_alias deploy-tablet-a)" = process ]
  [ "$(in_public public_process_alias '')" = '' ]
}

@test "an event kind passes only when the gates write it (docs/events.md)" {
  for kind in queue admit overcommit park unpark release reap corrupt \
    lock-wait lock-acquire lock-release lock-timeout stale kill; do
    [ "$(in_public public_event_kind "$kind")" = "$kind" ]
  done
  [ "$(in_public public_event_kind tablet-app-deploy)" = other ]
}

@test "event detail passes only in the numeric forms the gates write" {
  for detail in \
    'ticket 41, 2 units after 0s; used 5/6' \
    'ticket 7, 3 units admitted after max wait; used 7/6' \
    '2 units, was holding' \
    '3 units returned while waiting for the device' \
    'ticket 9 asks for 3 units back' \
    'pid 51120, parked, 3 units, waiter gone' \
    '2 line(s) dropped from the state file' \
    'pid 50112, age 1840s, fd 17' \
    'pid 50112 sent TERM by the watchdog' \
    'held for 312s' 'device busy' 'gave up after 3600s' ''; do
    [ "$(in_public public_detail "$detail")" = "$detail" ]
  done
  for detail in 'job e2e-android' 'job 42' 'ticket 4, see org/mobile-app' 'pid 1 /srv/runners/api'; do
    [ "$(in_public public_detail "$detail")" = '' ]
  done
}

@test "every class is one the filter knows" {
  run in_public public_classes
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -vE '^[a-z0-9_.]+ (keep|alias|share|numeric|never)$' <<< "$output"
  [ "$status" -eq 1 ]
}

@test "a unit and a worker directory take their runner's alias" {
  write_config
  mkdir -p "$GRM_RUNNERS_DIR/tablet-app" "$BATS_TEST_TMPDIR/elsewhere"
  [ "$(in_public public_unit_alias grm-runner-tablet-app.service)" = runner-2.service ]
  [ "$(in_public public_unit_alias grm-runner-api.service)" = other.service ]
  [ "$(in_public public_directory_alias "$(readlink -f "$GRM_RUNNERS_DIR/tablet-app")")" = runner-2 ]
  [ "$(in_public public_directory_alias "$BATS_TEST_TMPDIR/elsewhere")" = other ]
}

# Prints what public_field leaves in a variable holding $2 for field $1.
pick() {
  bash -c 'source "$GRM_ROOT/lib/common.sh"; source "$GRM_ROOT/lib/public.sh"
    value=$2; public_field value "$1" "${@:3}"; printf "%s" "$value"' _ "$@"
}

@test "a field is replaced as its class says, only in public output" {
  write_config
  export public_output=1
  [ "$(pick host.load_1m 4.31)" = 4.31 ]
  [ "$(pick runners.name web-app public_runner_alias)" = runner-3 ]
  [ "$(pick slots.records.job.run_id 8123456789)" = '' ]
  [ "$(pick runners.labels self-hosted,linux)" = '' ]
  [ "$(pick events.detail 'job e2e-android' public_detail)" = '' ]
  export GRM_RELAY_SHARE_DETAILS=1
  [ "$(pick runners.name web-app public_runner_alias)" = web-app ]
  [ "$(pick slots.records.job.run_id 8123456789)" = 8123456789 ]
  [ "$(pick events.detail 'job e2e-android' public_detail)" = 'job e2e-android' ]
  [ "$(pick runners.labels self-hosted,linux)" = '' ]
  [ "$(pick slots.records.job.actor dev-alex)" = '' ]
  public_output=0
  [ "$(pick runners.labels self-hosted,linux)" = self-hosted,linux ]
}

@test "a field without a class stops public output" {
  export public_output=1
  run pick host.hostname runner-host
  [ "$status" -eq 70 ]
  [[ $output == *'host.hostname has no public class'* ]]
  [[ $output != *runner-host* ]]
  public_output=0
  [ "$(pick host.hostname runner-host)" = runner-host ]
}
