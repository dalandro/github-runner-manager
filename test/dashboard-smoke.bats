#!/usr/bin/env bats
load helpers

# Starts the real dashboard in demo mode. Needs Elixir and fetched
# dependencies, so it is skipped elsewhere; CI runs it in the Elixir job.
export BATS_TEST_TIMEOUT=300
port=${GRM_SMOKE_PORT:-4290}

listeners() { ss -ltnH "sport = :$port"; }
is_listening() { [[ -n $(listeners) ]]; }
extra_host=runner-host.private.example
viewer=viewer@example.com
# The status line of a WebSocket handshake for the live socket from a page at
# the given origin. A refused origin is answered before the upgrade.
socket_handshake() {
  curl -sS -i --max-time 3 -o - \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H "Origin: $1" \
    "http://127.0.0.1:$port/live/websocket?vsn=2.0.0" 2> /dev/null | head -n 1
}
is_ready() { curl -fsS -o /dev/null "http://127.0.0.1:$port/robots.txt"; }
page_has() { curl -fsS "http://127.0.0.1:$port/" | grep -qF -- "$1"; }
wait_until_ready() { # <server pid>
  local attempt
  for ((attempt=0; attempt<240; attempt++)); do
    if is_ready; then return 0; fi
    kill -0 "$1"
    sleep 1
  done
  return 1
}

@test "dashboard serves demo data on loopback only and stops on TERM" {
  command -v mix > /dev/null || skip 'Elixir is not installed'
  [[ -d $GRM_ROOT/dashboard/deps/phoenix ]] || skip 'dashboard dependencies are not fetched'
  ! is_listening || skip "port $port is in use"

  "$GRM_ROOT/bin/grm-dashboard" --demo --port "$port" --allow-host "$extra_host" --viewer "$viewer" > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
  server=$!
  processes+=("$server")
  wait_until_ready "$server"

  # Bound to 127.0.0.1 and nothing else.
  run listeners
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *"127.0.0.1:$port"* ]]

  # The page is rendered on the server, from the bundled demo reading, for a
  # listed viewer only, on loopback too.
  run curl -fsS -H "Tailscale-User-Login: $viewer" "http://127.0.0.1:$port/"
  [ "$status" -eq 0 ]
  [[ $output == *'Demo data'* && $output == *'org/mobile-app'* ]]
  run curl -sS -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' "http://127.0.0.1:$port/"
  [ "$output" = 403 ]
  ! grep -q 'org/' "$BATS_TEST_TMPDIR/body"
  run curl -fsS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/assets/app.css"
  [ "$output" = 200 ]

  # No path leads outside the static directories.
  local path
  for path in '/assets/../../mix.exs' '/assets/%2e%2e/%2e%2e/mix.exs' '/vendor/phoenix/../../mix.exs' '/../mix.exs'; do
    run curl -sS --path-as-is -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' "http://127.0.0.1:$port$path"
    [[ $output == 400 || $output == 404 ]]
    ! grep -q defmodule "$BATS_TEST_TMPDIR/body"
  done

  # A request for any other host name is refused (DNS rebinding).
  run curl -sS -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' "http://127.0.0.1:$port/"
  [ "$output" = 403 ]

  # The one extra name given with --allow-host is answered, as a proxy on
  # this machine would ask for it, to the listed viewer only; forwarded
  # headers count for nothing.
  run curl -sS -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -H "Host: $extra_host" \
    -H "Tailscale-User-Login: $viewer" "http://127.0.0.1:$port/"
  [ "$output" = 200 ]
  grep -q 'org/mobile-app' "$BATS_TEST_TMPDIR/body"
  run curl -sS -o "$BATS_TEST_TMPDIR/body" -w '%{http_code}' -H "Host: $extra_host" "http://127.0.0.1:$port/"
  [ "$output" = 403 ]
  ! grep -q 'org/' "$BATS_TEST_TMPDIR/body"
  run curl -sS -o /dev/null -w '%{http_code}' -H "Host: $extra_host" \
    -H 'Tailscale-User-Login: stranger@example.com' "http://127.0.0.1:$port/"
  [ "$output" = 403 ]
  run curl -sS -o /dev/null -w '%{http_code}' -H 'Host: attacker.example' \
    -H "X-Forwarded-Host: $extra_host" "http://127.0.0.1:$port/"
  [ "$output" = 403 ]

  # The live socket opens for a page served under an allowed name only.
  run socket_handshake "https://$extra_host"
  [[ $output == *' 101 '* ]]
  run socket_handshake "http://localhost:$port"
  [[ $output == *' 101 '* ]]
  run socket_handshake 'https://attacker.example'
  [[ $output == *' 403 '* ]]

  kill -TERM "$server"
  wait "$server"
  ! is_listening
}

@test "relay mode on loopback shows a push made with a push token only" {
  command -v mix > /dev/null || skip 'Elixir is not installed'
  [[ -d $GRM_ROOT/dashboard/deps/phoenix ]] || skip 'dashboard dependencies are not fetched'
  ! is_listening || skip "port $port is in use"

  local token document=$GRM_ROOT/dashboard/priv/demo/status.json
  token=$(head -c 30 /dev/urandom | base64)
  GRM_RELAY_PUSH_TOKENS=$token "$GRM_ROOT/bin/grm-dashboard" --relay --port "$port" > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
  server=$!
  processes+=("$server")
  wait_until_ready "$server"

  run listeners
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *"127.0.0.1:$port"* ]]

  run curl -fsS "http://127.0.0.1:$port/"
  [ "$status" -eq 0 ]
  [[ $output == *'No report yet'* && $output != *'org/'* ]]

  # Without the token nothing is kept.
  run curl -sS -o /dev/null -w '%{http_code}' --data-binary "@$document" "http://127.0.0.1:$port/ingest"
  [ "$output" = 401 ]
  run curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong-token-of-thirty-two-chars-x' \
    --data-binary "@$document" "http://127.0.0.1:$port/ingest"
  [ "$output" = 401 ]
  run curl -fsS "http://127.0.0.1:$port/"
  [[ $output != *'org/'* ]]

  # The token reaches curl through a config on a file descriptor, not argv.
  run curl -sS -w ' %{http_code}' --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    --data-binary "@$document" "http://127.0.0.1:$port/ingest"
  [ "$output" = '{"next_push_seconds":5} 200' ]
  # The page reads the relay's inbox every second.
  wait_for page_has 'org/mobile-app'
  page_has 'cannot reach the host'
  # Mid-test, `! cmd` cannot fail a test; check the status instead.
  run grep -qF -- "$token" "$BATS_TEST_TMPDIR/server.log"
  [ "$status" -eq 1 ]

  kill -TERM "$server"
  wait "$server"
  ! is_listening
}

@test "the pusher's public document shows on a loopback relay, aliased unless shared" {
  command -v mix > /dev/null || skip 'Elixir is not installed'
  [[ -d $GRM_ROOT/dashboard/deps/phoenix ]] || skip 'dashboard dependencies are not fetched'
  ! is_listening || skip "port $port is in use"

  local token
  token=$(head -c 30 /dev/urandom | base64)
  GRM_RELAY_PUSH_TOKENS=$token "$GRM_ROOT/bin/grm-dashboard" --relay --port "$port" > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
  server=$!
  processes+=("$server")
  wait_until_ready "$server"

  # A test installation with demo names, never this machine's own state.
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config.env" GRM_SYSTEMCTL=true GRM_PROC="$BATS_TEST_TMPDIR/proc"
  printf 'GRM_RUNNERS=("mobile-app org/mobile-app 3" "web-app org/web-app 1")\n' > "$GRM_CONFIG"
  mkdir -p "$GRM_PROC"
  printf '1.50 0 0\n' > "$GRM_PROC/loadavg"
  printf 'MemAvailable: 4194304 kB\n' > "$GRM_PROC/meminfo"
  export GRM_RELAY_URL="http://127.0.0.1:$port/ingest" GRM_RELAY_TOKEN_FILE="$BATS_TEST_TMPDIR/relay-token"
  (umask 077; printf '%s\n' "$token" > "$GRM_RELAY_TOKEN_FILE")

  run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$output" = 'grm-relay-push: pushed' ]
  wait_for page_has 'runner-1'
  run curl -fsS "http://127.0.0.1:$port/"
  [[ $output == *'repo-2'* && $output != *'mobile-app'* ]]

  GRM_RELAY_SHARE_DETAILS=1 run "$GRM_ROOT/bin/grm-relay-push" --once
  [ "$output" = 'grm-relay-push: pushed' ]
  wait_for page_has 'org/mobile-app'

  run grep -qF -- "$token" "$BATS_TEST_TMPDIR/server.log"
  [ "$status" -eq 1 ]
  kill -TERM "$server"
  wait "$server"
  ! is_listening
}
