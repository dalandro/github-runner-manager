#!/usr/bin/env bats
load helpers

configure_runner() {
  export GRM_CONFIG="$BATS_TEST_TMPDIR/config"
  printf 'GRM_RUNNERS=("repo-a org/repo-a 3 self-hosted,linux,emulator")\n' > "$GRM_CONFIG"
  mkdir -p "$GRM_RUNNERS_DIR/repo-a"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$GRM_RUNNERS_DIR/repo-a/run.sh"
  chmod +x "$GRM_RUNNERS_DIR/repo-a/run.sh"
  export GRM_SYSTEMCTL="$BATS_TEST_TMPDIR/systemctl"
  export SYSTEMCTL_LOG="$BATS_TEST_TMPDIR/systemctl.log"
  cat > "$GRM_SYSTEMCTL" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [[ $1 == is-active ]]; then exit "${STUB_ACTIVE:-1}"; fi
if [[ $1 == stop || $1 == disable ]]; then
  [[ -f $GRM_SYSTEMD_USER_DIR/$2 ]] || exit 5
fi
if [[ $1 == show ]]; then
  if [[ -f $GRM_SYSTEMD_USER_DIR/${@: -1} ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi
fi
SCRIPT
  chmod +x "$GRM_SYSTEMCTL"
}

@test "install renders unit and updates env idempotently preserving unrelated values" {
  configure_runner
  printf 'UNRELATED=value\nGRM_JOB_UNITS=9\nGRM_JOB_UNITS=8\n' > "$GRM_RUNNERS_DIR/repo-a/.env"
  "$GRM_ROOT/bin/grm-install-runner" --enable --watchdog repo-a
  "$GRM_ROOT/bin/grm-install-runner" repo-a
  unit=$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service
  grep -Fx "WorkingDirectory=$GRM_RUNNERS_DIR/repo-a" "$unit"
  grep -F "ExecStart=\"$GRM_RUNNERS_DIR/repo-a/run.sh\"" "$unit"
  grep -F 'KillSignal=SIGINT' "$unit"
  grep -F 'UNRELATED=value' "$GRM_RUNNERS_DIR/repo-a/.env"
  [ "$(grep -c '^GRM_JOB_UNITS=' "$GRM_RUNNERS_DIR/repo-a/.env")" -eq 1 ]
  grep -F 'GRM_JOB_UNITS=3' "$GRM_RUNNERS_DIR/repo-a/.env"
  grep -F "ACTIONS_RUNNER_HOOK_JOB_STARTED=$(readlink -f "$GRM_ROOT/hooks/job-started")" "$GRM_RUNNERS_DIR/repo-a/.env"
  grep -F "GRM_CONFIG=$GRM_CONFIG" "$GRM_RUNNERS_DIR/repo-a/.env"
  [ "$(stat -c %a "$GRM_RUNNERS_DIR/repo-a/.env")" = 600 ]
  grep -Fx 'daemon-reload' "$SYSTEMCTL_LOG"
  grep -Fx 'enable --now grm-runner-repo-a.service' "$SYSTEMCTL_LOG"
  [ -f "$GRM_SYSTEMD_USER_DIR/grm-stale-lock-watchdog.timer" ]
}

@test "runner unit sets the hardening that needs no namespaces, and nothing a job relies on" {
  configure_runner
  "$GRM_ROOT/bin/grm-install-runner" repo-a
  unit=$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service
  for directive in NoNewPrivileges RestrictSUIDSGID LockPersonality RestrictRealtime; do
    grep -Fx "$directive=yes" "$unit"
  done
  # Decided off in docs/runner-units.md#hardening: each needs a namespace a
  # user manager may not get, or breaks JIT compilers, emulators or sandboxes.
  ! grep -E '^(PrivateTmp|ProtectSystem|ProtectHome|PrivateDevices|PrivateUsers|ReadOnlyPaths|MemoryDenyWriteExecute|RestrictNamespaces|SystemCallArchitectures)=' "$unit"
}

@test "active runner is never implicitly restarted" {
  configure_runner
  run env STUB_ACTIVE=0 "$GRM_ROOT/bin/grm-install-runner" --enable repo-a
  [ "$status" -eq 0 ]
  [[ $output == *'restart grm-runner-repo-a.service when idle to apply'* ]]
  ! grep -E '^(restart|enable --now)' "$SYSTEMCTL_LOG"
}

@test "unknown runner and missing run script fail before changes" {
  configure_runner
  run "$GRM_ROOT/bin/grm-install-runner" unknown
  [ "$status" -eq 2 ]
  mv "$GRM_RUNNERS_DIR/repo-a/run.sh" "$GRM_RUNNERS_DIR/repo-a/other"
  run "$GRM_ROOT/bin/grm-install-runner" repo-a
  [ "$status" -eq 2 ]
  [ ! -e "$GRM_SYSTEMD_USER_DIR" ]
}

@test "uninstall removes managed env entries and unit but leaves registration and files" {
  configure_runner
  printf 'UNRELATED=value\n' > "$GRM_RUNNERS_DIR/repo-a/.env"
  "$GRM_ROOT/bin/grm-install-runner" repo-a
  run "$GRM_ROOT/bin/grm-uninstall-runner" repo-a
  [ "$status" -eq 0 ]
  [[ $output == *'./config.sh remove'* ]]
  [ ! -e "$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service" ]
  [ "$(<"$GRM_RUNNERS_DIR/repo-a/.env")" = UNRELATED=value ]
  [ -f "$GRM_RUNNERS_DIR/repo-a/run.sh" ]
  grep -Fx 'stop grm-runner-repo-a.service' "$SYSTEMCTL_LOG"
  grep -Fx 'disable grm-runner-repo-a.service' "$SYSTEMCTL_LOG"
}

@test "rendered runner and watchdog units pass systemd verification" {
  command -v systemd-analyze >/dev/null || skip 'systemd-analyze is not installed'
  configure_runner
  export GRM_RUNNERS_DIR="$BATS_TEST_TMPDIR/runners with % space"
  mkdir -p "$GRM_RUNNERS_DIR"
  mv "$BATS_TEST_TMPDIR/runners/repo-a" "$GRM_RUNNERS_DIR/"
  "$GRM_ROOT/bin/grm-install-runner" --watchdog repo-a
  run systemd-analyze verify "$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service" \
    "$GRM_SYSTEMD_USER_DIR/grm-stale-lock-watchdog.service" \
    "$GRM_SYSTEMD_USER_DIR/grm-stale-lock-watchdog.timer"
  [ "$status" -eq 0 ]
  grep -Fx "WorkingDirectory=${GRM_RUNNERS_DIR//%/%%}/repo-a" "$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service"
}

@test "install rejects directory edge whitespace and newlines" {
  configure_runner
  for directory in ' runners' 'runners ' $'runners\nextra'; do
    run env GRM_RUNNERS_DIR="$directory" "$GRM_ROOT/bin/grm-install-runner" repo-a
    [ "$status" -eq 2 ]
    [[ $output == *'directory paths'* ]]
  done
  [ ! -e "$GRM_SYSTEMD_USER_DIR" ]
}

@test "uninstall succeeds twice without changing the cleaned runner" {
  configure_runner
  printf 'UNRELATED=value\n' > "$GRM_RUNNERS_DIR/repo-a/.env"
  "$GRM_ROOT/bin/grm-install-runner" repo-a
  "$GRM_ROOT/bin/grm-uninstall-runner" repo-a
  cp "$GRM_RUNNERS_DIR/repo-a/.env" "$BATS_TEST_TMPDIR/before"
  before=$(stat -c '%i %Y %Z %a' "$GRM_RUNNERS_DIR/repo-a/.env")
  run "$GRM_ROOT/bin/grm-uninstall-runner" repo-a
  [ "$status" -eq 0 ]
  [ ! -e "$GRM_SYSTEMD_USER_DIR/grm-runner-repo-a.service" ]
  cmp "$BATS_TEST_TMPDIR/before" "$GRM_RUNNERS_DIR/repo-a/.env"
  [ "$(stat -c '%i %Y %Z %a' "$GRM_RUNNERS_DIR/repo-a/.env")" = "$before" ]
}

@test "uninstall cleans managed env when the unit is already missing" {
  configure_runner
  printf 'UNRELATED=value\nGRM_JOB_UNITS=3\n' > "$GRM_RUNNERS_DIR/repo-a/.env"
  run "$GRM_ROOT/bin/grm-uninstall-runner" repo-a
  [ "$status" -eq 0 ]
  [ "$(<"$GRM_RUNNERS_DIR/repo-a/.env")" = UNRELATED=value ]
}
