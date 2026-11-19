#!/usr/bin/env bats
load helpers

token=0123456789abcdef0123456789abcdef-push

in_relay() {
  # shellcheck source=lib/relay.sh
  bash -c 'source "$GRM_ROOT/lib/common.sh"; source "$GRM_ROOT/lib/relay.sh"; "$@"' _ "$@"
}

write_token() {
  export GRM_RELAY_TOKEN_FILE="$BATS_TEST_TMPDIR/relay-token"
  printf '%s\n' "${1:-$token}" > "$GRM_RELAY_TOKEN_FILE"
  chmod 600 "$GRM_RELAY_TOKEN_FILE"
}

# A curl that records its arguments, the config it was given and the body,
# and answers with the next status code from codes (the last one repeats).
stub_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' "${@:-200}" > "$BATS_TEST_TMPDIR/codes"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'SCRIPT'
#!/usr/bin/env bash
stub=$(dirname "$0")/..
printf '%s\n' "$@" >> "$stub/curl-argv"
output=/dev/null
while (($#)); do
  case $1 in
    --config) cat "$2" >> "$stub/curl-config"; shift;;
    --output) output=$2; shift;;
  esac
  shift
done
cat > "$stub/curl-body"
code=$(head -n 1 "$stub/codes")
if (($(wc -l < "$stub/codes") > 1)); then sed -i 1d "$stub/codes"; fi
[[ $code == exit* ]] && exit "${code#exit }"
printf '%s' "${STUB_RESPONSE-{\"next_push_seconds\":5\}}" > "$output"
printf '%s' "$code"
SCRIPT
  # A sleep that records each delay and stops the pusher after STUB_SLEEPS.
  cat > "$BATS_TEST_TMPDIR/bin/sleep" <<'SCRIPT'
#!/usr/bin/env bash
stub=$(dirname "$0")/..
printf '%s\n' "$1" >> "$stub/sleeps"
(($(wc -l < "$stub/sleeps") < ${STUB_SLEEPS:-1}))
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/bin/curl" "$BATS_TEST_TMPDIR/bin/sleep"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" GRM_SYSTEMCTL=true
  export GRM_RELAY_URL=https://relay.example.com/ingest
  export GRM_PROC="$BATS_TEST_TMPDIR/proc"
  mkdir -p "$GRM_PROC"
  printf '1.50 0 0\n' > "$GRM_PROC/loadavg"
  printf 'MemAvailable: 4194304 kB\n' > "$GRM_PROC/meminfo"
}

@test "a relay URL is https, or http to this machine only" {
  [ "$(in_relay relay_url_protocol https://relay.example.com/ingest)" = https ]
  [ "$(in_relay relay_url_protocol https://relay.example.com:8443/ingest)" = https ]
  [ "$(in_relay relay_url_protocol http://127.0.0.1:4391/ingest)" = http ]
  [ "$(in_relay relay_url_protocol 'http://[::1]:4391/ingest')" = http ]
  for url in '' http://relay.example.com/ingest http://127.0.0.1.example.com/ingest \
    ftp://relay.example.com 'https://relay.example.com/in gest' https://user@relay.example.com/ingest; do
    run in_relay relay_url_protocol "$url"
    [ "$status" -ne 0 ] || { echo "accepted $url"; return 1; }
  done
}

@test "the next push comes when the relay asks, clamped to 2..300 seconds" {
  [ "$(in_relay relay_next_interval '{"next_push_seconds": 5}')" = 5 ]
  [ "$(in_relay relay_next_interval '{"next_push_seconds":1}')" = 2 ]
  [ "$(in_relay relay_next_interval '{"next_push_seconds": 86400}')" = 300 ]
  [ "$(in_relay relay_next_interval '{"next_push_seconds": 99999999999999999999}')" = 300 ]
  [ "$(in_relay relay_next_interval '{"next_push_seconds": 0005}')" = 5 ]
  [ "$(in_relay relay_next_interval '{"next_push_seconds": 000}')" = 2 ]
  [ "$(in_relay relay_next_interval 'not json')" = 5 ]
  [ "$(in_relay relay_next_interval '')" = 5 ]
}

@test "failures back off exponentially to five minutes, with jitter below the step" {
  [ "$(in_relay relay_backoff 1 5 0)" = 10 ]
  [ "$(in_relay relay_backoff 2 5 0)" = 20 ]
  [ "$(in_relay relay_backoff 6 5 0)" = 300 ]
  [ "$(in_relay relay_backoff 60 5 0)" = 300 ]
  [ "$(in_relay relay_backoff 1 5 32767)" -ge 8 ]
  [ "$(in_relay relay_backoff 60 5 32767)" -ge 225 ]
}

@test "the token comes from a private file, one line of 32 or more visible characters" {
  write_token
  [ "$(in_relay relay_read_token "$GRM_RELAY_TOKEN_FILE")" = "$token" ]
  chmod 640 "$GRM_RELAY_TOKEN_FILE"
  run in_relay relay_read_token "$GRM_RELAY_TOKEN_FILE"
  [ "$status" -ne 0 ]
  [[ $output == *'chmod 600'* && $output != *"$token"* ]]
  for bad in short 'has space inside it, 32 characters long' "$token\"quote" "$token\\"; do
    write_token "$bad"
    run in_relay relay_read_token "$GRM_RELAY_TOKEN_FILE"
    [ "$status" -ne 0 ] || { echo "accepted $bad"; return 1; }
    [[ $output != *"$bad"* ]]
  done
  run in_relay relay_read_token "$BATS_TEST_TMPDIR/missing"
  [ "$status" -ne 0 ]
}

@test "the pusher refuses to start without an https URL or a private token" {
  stub_curl
  write_token
  GRM_RELAY_URL= run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 2 ]
  GRM_RELAY_URL=http://relay.example.com/ingest run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 2 ]
  [[ $output == *https* ]]
  chmod 644 "$GRM_RELAY_TOKEN_FILE"
  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 2 ]
  [[ $output != *"$token"* ]]
  run "$GRM_ROOT/bin/grm-relay-push" --forever
  [ "$status" -eq 2 ]
  [ ! -e "$BATS_TEST_TMPDIR/curl-argv" ]
}

@test "a push sends the public document, with the token in a config, never in argv" {
  stub_curl 200
  write_token
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config.env"
  printf 'GRM_RUNNERS=("mobile-app org/mobile-app 3")\n' > "$GRM_CONFIG"
  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 0 ]
  [ "$output" = 'grm-relay-push: pushed' ]
  run grep -cF -- "$token" "$BATS_TEST_TMPDIR/curl-argv"
  [ "$output" = 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/curl-config")" = "header = \"Authorization: Bearer $token\"" ]
  grep -qx -- '=https' "$BATS_TEST_TMPDIR/curl-argv"
  grep -qx -- '--max-time' "$BATS_TEST_TMPDIR/curl-argv"
  grep -qx -- 'https://relay.example.com/ingest' "$BATS_TEST_TMPDIR/curl-argv"
  grep -qF '"name": "runner-1"' "$BATS_TEST_TMPDIR/curl-body"
  run grep -cF mobile-app "$BATS_TEST_TMPDIR/curl-body"
  [ "$output" = 0 ]
}

@test "curl reads no curlrc, expands no globs, and goes to loopback without a proxy" {
  stub_curl 200
  write_token
  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$(head -n 1 "$BATS_TEST_TMPDIR/curl-argv")" = -q ]
  grep -qx -- --globoff "$BATS_TEST_TMPDIR/curl-argv"
  run grep -cx -- --noproxy "$BATS_TEST_TMPDIR/curl-argv"
  [ "$output" = 0 ]
  rm "$BATS_TEST_TMPDIR/curl-argv"
  GRM_RELAY_URL=http://127.0.0.1:4391/ingest run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 0 ]
  grep -qx -- '=http' "$BATS_TEST_TMPDIR/curl-argv"
  grep -A1 -x -- --noproxy "$BATS_TEST_TMPDIR/curl-argv" | grep -qx '[*]'
}

@test "a refused push fails once and says why, without the token" {
  stub_curl 401
  write_token
  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 1 ]
  [[ $output == *'HTTP 401'* && $output != *"$token"* ]]
  stub_curl 'exit 7'
  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$status" -eq 1 ]
  [[ $output == *'curl exit 7'* ]]
}

@test "pushing waits as long as the relay asks, within the clamp" {
  stub_curl 200
  write_token
  STUB_RESPONSE='{"next_push_seconds": 1}' run "$GRM_ROOT/bin/grm-relay-push"
  STUB_RESPONSE='{"next_push_seconds": 9000}' run "$GRM_ROOT/bin/grm-relay-push"
  STUB_RESPONSE='' run "$GRM_ROOT/bin/grm-relay-push"
  [ "$(cat "$BATS_TEST_TMPDIR/sleeps")" = $'2\n300\n5' ]
  [ "$output" = '' ]
}

@test "failures back off and are logged once, then the recovery once" {
  stub_curl 500 500 500 500 500 200 200
  write_token
  STUB_SLEEPS=7 run "$GRM_ROOT/bin/grm-relay-push"
  mapfile -t sleeps < "$BATS_TEST_TMPDIR/sleeps"
  [ "${#sleeps[@]}" -eq 7 ]
  bases=(10 20 40 80 160)
  for index in 0 1 2 3 4; do
    ((sleeps[index] <= bases[index] && sleeps[index] * 4 >= bases[index] * 3)) || { echo "sleep ${sleeps[index]} for ${bases[index]}"; return 1; }
  done
  [ "${sleeps[5]}" = 5 ]
  [ "$(grep -c 'push failed: HTTP 500' <<< "$output")" -eq 1 ]
  [ "$(grep -c 'pushed again after 5 failed attempts' <<< "$output")" -eq 1 ]
  [ "$(wc -l <<< "$output")" -eq 2 ]
}

@test "the unit template runs the pusher at lowest priority with small caps and no secret" {
  unit=$GRM_ROOT/systemd/grm-relay-push.service.in
  grep -Fx 'ExecStart=@GRM_ROOT@/bin/grm-relay-push' "$unit"
  grep -Fx 'Nice=19' "$unit"
  grep -Fx 'IOSchedulingClass=idle' "$unit"
  grep -Fx 'MemoryMax=64M' "$unit"
  grep -Ex 'TasksMax=[0-9]+' "$unit"
  run grep -E '^Environment=.*(TOKEN|URL)' "$unit"
  [ "$status" -eq 1 ]
}
