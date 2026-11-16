#!/usr/bin/env bats
load helpers

# The launcher is tested against a stand-in dashboard directory and a stub
# `mix`, so these run without Elixir. test/dashboard-smoke.bats starts the
# real server where Elixir is installed.
setup_dashboard() {
  export GRM_DASHBOARD_DIR="$BATS_TEST_TMPDIR/dashboard"
  mkdir -p "$GRM_DASHBOARD_DIR/deps/phoenix" "$BATS_TEST_TMPDIR/stubs"
  cat > "$BATS_TEST_TMPDIR/stubs/mix" <<'SCRIPT'
#!/usr/bin/env bash
printf 'mix %s\n' "$*"
printf 'directory=%s\n' "$PWD"
printf 'PORT=%s PHX_SERVER=%s MIX_ENV=%s\n' "$PORT" "$PHX_SERVER" "$MIX_ENV"
printf 'source=%s command=%s\n' "$GRM_DASHBOARD_SOURCE" "$GRM_STATUS_COMMAND"
printf 'allowed_hosts=[%s]\n' "$GRM_DASHBOARD_ALLOWED_HOSTS"
SCRIPT
  chmod +x "$BATS_TEST_TMPDIR/stubs/mix"
  export PATH="$BATS_TEST_TMPDIR/stubs:$PATH"
}

@test "dashboard starts the server on the default port reading grm-status" {
  setup_dashboard
  run "$GRM_ROOT/bin/grm-dashboard"
  [ "$status" -eq 0 ]
  [[ $output == *'http://127.0.0.1:4290'* ]]
  [[ $output == *'mix phx.server'* ]]
  [[ $output == *"directory=$GRM_DASHBOARD_DIR"* ]]
  [[ $output == *'PORT=4290 PHX_SERVER=true MIX_ENV=prod'* ]]
  [[ $output == *'source=command command='*'/bin/grm-status'* ]]
  [[ $output == *'allowed_hosts=[]'* && $output != *'also answers to'* ]]
}

@test "dashboard --allow-host adds names to those from the environment" {
  setup_dashboard
  run "$GRM_ROOT/bin/grm-dashboard" --allow-host runner-host.private.example
  [ "$status" -eq 0 ]
  [[ $output == *'http://127.0.0.1:4290'* ]]
  [[ $output == *'also answers to: runner-host.private.example'* ]]
  [[ $output == *'allowed_hosts=[runner-host.private.example]'* ]]
  GRM_DASHBOARD_ALLOWED_HOSTS=one.example run "$GRM_ROOT/bin/grm-dashboard" --allow-host two.example --allow-host three
  [ "$status" -eq 0 ]
  [[ $output == *'allowed_hosts=[one.example,two.example,three]'* ]]
}

@test "dashboard rejects allowed hosts that are not plain names" {
  setup_dashboard
  local name
  for name in '*.private.example' '*' 'https://host.example' 'host.example:443' 'host.example/path' \
    '.example' 'host..example' '-host.example' 'a,,b' 'a b' ''; do
    run "$GRM_ROOT/bin/grm-dashboard" --allow-host "$name"
    [ "$status" -eq 2 ]
    [[ $output != *'mix '* ]]
  done
  GRM_DASHBOARD_ALLOWED_HOSTS='*.example' run "$GRM_ROOT/bin/grm-dashboard"
  [ "$status" -eq 2 ]
  run "$GRM_ROOT/bin/grm-dashboard" --allow-host
  [ "$status" -eq 2 ]
}

@test "dashboard --demo serves the bundled data and --port picks the port" {
  setup_dashboard
  run "$GRM_ROOT/bin/grm-dashboard" --demo --port 4291
  [ "$status" -eq 0 ]
  [[ $output == *'PORT=4291 '* && $output == *'source=demo '* ]]
}

@test "dashboard fetches dependencies on the first run only" {
  setup_dashboard
  run "$GRM_ROOT/bin/grm-dashboard"
  [[ $output != *'deps.get'* ]]
  rmdir "$GRM_DASHBOARD_DIR/deps/phoenix"
  run "$GRM_ROOT/bin/grm-dashboard"
  [ "$status" -eq 0 ]
  [[ $output == *'mix deps.get --only prod'*'mix phx.server'* ]]
}

@test "dashboard prefers a built release" {
  setup_dashboard
  mkdir -p "$GRM_DASHBOARD_DIR/_build/prod/rel/dashboard/bin"
  cat > "$GRM_DASHBOARD_DIR/_build/prod/rel/dashboard/bin/dashboard" <<'SCRIPT'
#!/usr/bin/env bash
printf 'release %s PORT=%s source=%s hosts=%s\n' "$*" "$PORT" "$GRM_DASHBOARD_SOURCE" "$GRM_DASHBOARD_ALLOWED_HOSTS"
SCRIPT
  chmod +x "$GRM_DASHBOARD_DIR/_build/prod/rel/dashboard/bin/dashboard"
  run "$GRM_ROOT/bin/grm-dashboard" --demo --allow-host runner-host.private.example
  [ "$status" -eq 0 ]
  [ "$output" = 'release start PORT=4290 source=demo hosts=runner-host.private.example' ]
}

@test "dashboard rejects bad arguments" {
  setup_dashboard
  local arguments
  for arguments in '--port' '--port 0' '--port 65536' '--port 80a' '--host 0.0.0.0' 'extra'; do
    # shellcheck disable=SC2086
    run "$GRM_ROOT/bin/grm-dashboard" $arguments
    [ "$status" -eq 2 ]
    [[ $output != *'mix '* ]]
  done
}

@test "dashboard without Elixir points at the terminal view" {
  setup_dashboard
  local tool
  mkdir "$BATS_TEST_TMPDIR/tools"
  for tool in bash env readlink dirname getconf; do
    ln -s "$(command -v "$tool")" "$BATS_TEST_TMPDIR/tools/$tool"
  done
  PATH="$BATS_TEST_TMPDIR/tools" run "$GRM_ROOT/bin/grm-dashboard"
  [ "$status" -eq 1 ]
  [[ $output == *'grm-status --watch'* ]]
}
