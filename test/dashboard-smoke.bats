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

@test "dashboard serves demo data on loopback only and stops on TERM" {
  command -v mix > /dev/null || skip 'Elixir is not installed'
  [[ -d $GRM_ROOT/dashboard/deps/phoenix ]] || skip 'dashboard dependencies are not fetched'
  ! is_listening || skip "port $port is in use"

  "$GRM_ROOT/bin/grm-dashboard" --demo --port "$port" --allow-host "$extra_host" --viewer "$viewer" > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
  server=$!
  processes+=("$server")
  local attempt
  for ((attempt=0; attempt<240; attempt++)); do
    if is_ready; then break; fi
    kill -0 "$server"
    sleep 1
  done

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
