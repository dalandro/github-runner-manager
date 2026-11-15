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
printf 'release %s PORT=%s source=%s\n' "$*" "$PORT" "$GRM_DASHBOARD_SOURCE"
SCRIPT
  chmod +x "$GRM_DASHBOARD_DIR/_build/prod/rel/dashboard/bin/dashboard"
  run "$GRM_ROOT/bin/grm-dashboard" --demo
  [ "$status" -eq 0 ]
  [ "$output" = 'release start PORT=4290 source=demo' ]
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
