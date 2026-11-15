#!/usr/bin/env bats
load helpers

# Starts the real dashboard in demo mode. Needs Elixir and fetched
# dependencies, so it is skipped elsewhere; CI runs it in the Elixir job.
export BATS_TEST_TIMEOUT=300
port=${GRM_SMOKE_PORT:-4290}

listeners() { ss -ltnH "sport = :$port"; }
is_listening() { [[ -n $(listeners) ]]; }
is_ready() { curl -fsS -o /dev/null "http://127.0.0.1:$port/"; }

@test "dashboard serves demo data on loopback only and stops on TERM" {
  command -v mix > /dev/null || skip 'Elixir is not installed'
  [[ -d $GRM_ROOT/dashboard/deps/phoenix ]] || skip 'dashboard dependencies are not fetched'
  ! is_listening || skip "port $port is in use"

  "$GRM_ROOT/bin/grm-dashboard" --demo --port "$port" > "$BATS_TEST_TMPDIR/server.log" 2>&1 &
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

  # The page is rendered on the server, from the bundled demo reading.
  run curl -fsS "http://127.0.0.1:$port/"
  [ "$status" -eq 0 ]
  [[ $output == *'Demo data'* && $output == *'org/mobile-app'* ]]
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

  kill -TERM "$server"
  wait "$server"
  ! is_listening
}
