# Runner units

Register and label each runner manually first. `grm-install-runner [--enable]
[--watchdog] name` requires a configured name and existing `run.sh`. It renders
one user unit: runner directory, run.sh, automatic restart after ten seconds,
SIGINT for graceful runner shutdown, and a sixty-second stop timeout. systemd's
default control-group cleanup also applies; this toolkit does not manage tokens.

Installation atomically rewrites `.env` at mode 600, preserving unrelated lines
and reserving both job-hook keys, `GRM_JOB_UNITS`, and `GRM_CONFIG`. A config path
is written only when the selected config file exists. Repeated install removes
duplicate managed entries. Pre-existing values of those reserved keys are not
backed up; migrate any existing hook behaviour explicitly before installing.

Every install reloads the manager. `--enable` enables and starts an inactive unit;
an already active unit is only enabled, with a reminder to restart when idle.
Runners read `.env` at startup. No implicit restart interrupts an active job.
Labels in configuration are informational and never change runner registration.

`grm-uninstall-runner name` stops/disables the unit, removes it and the four
managed environment keys, then reloads the manager. It keeps runner files and
registration. Removing registration is an operator action: `./config.sh remove`
requires a removal token. The watchdog is shared and remains installed.

Exported environment wins over config, which wins over defaults. Arrays live in
config. Shared state must be configured in the file for installed hooks/timer;
transient shell exports do not become service environment. Use absolute paths.
Systemd paths are quoted, escaping backslashes, quotes, specifiers and (for exec)
dollars. `GRM_SYSTEMCTL` is split into an argument array without shell evaluation;
its executable path cannot contain spaces. Unit installation is not transactional
with systemctl; a manager failure may leave rendered files for inspection/retry.
