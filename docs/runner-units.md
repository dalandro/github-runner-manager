# Runner units

Register and label each runner manually first. `grm-install-runner [--enable]
[--watchdog] name` requires a configured name and existing `run.sh`. It renders
one user unit: runner directory, run.sh, automatic restart after ten seconds,
SIGINT for graceful runner shutdown, a sixty-second stop timeout and the
[hardening](#hardening) below. systemd's default control-group cleanup also
applies when the unit stops; this toolkit does not manage tokens. Units already
installed keep their old settings until `grm-install-runner` renders them again
and the runner restarts.

Installation atomically rewrites `.env` at mode 600, preserving unrelated lines
and reserving both job-hook keys, `GRM_JOB_UNITS`, and `GRM_CONFIG`. A config path
is written only when the selected config file exists. Repeated install removes
duplicate managed entries. Pre-existing values of those reserved keys are not
backed up; migrate any existing hook behaviour explicitly before installing.
Hook paths end in `.sh` because the runner requires a script extension.

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

## Upgrading

A new version can change what the installer writes, such as the hook paths.
Stop every runner using the checkout once idle, pull, re-run the installer for
each runner, then start them:

```bash
systemctl --user stop grm-runner-repo-a.service   # GRM_UNIT_PREFIX + name; each runner
git pull
bin/grm-install-runner repo-a   # each runner; same flags as the first install
systemctl --user start grm-runner-repo-a.service   # each runner
```

A running runner keeps the hook paths it read from `.env` at startup, so a pull
under it can remove a hook its next job needs. The installer replaces the
managed `.env` keys, never appends, and never restarts an active unit
(`--enable` only enables it), so the stop and start are required.

## Hardening

A runner runs whatever its jobs say, as its account. The unit narrows what a
job can do with that account only where nothing a build needs breaks. These
are user units: a job can reach the same user manager (`systemctl --user`,
`systemd-run --user`) and start a process without any of the settings below,
so they make abuse harder, not impossible. The boundary is the account: see
[separate accounts](#separate-accounts).

On:

| Setting | Effect | Why it is safe |
| --- | --- | --- |
| `NoNewPrivileges=yes` | No process in the unit gains privileges: set-user-ID programs such as `sudo` and `su` run without them. | Builds, emulators and the runner itself need no privileges. A job that relied on `sudo` stops working; give it a GitHub-hosted runner, or turn the setting off for that unit with `systemctl --user edit` and accept the risk. |
| `RestrictSUIDSGID=yes` | Jobs cannot create set-user-ID or set-group-ID files. | Nothing in a build should. |
| `LockPersonality=yes` | Jobs cannot change the kernel execution domain. | Only legacy emulation layers use it. |
| `RestrictRealtime=yes` | Jobs cannot take real-time scheduling and starve the host. | Builds and emulators run at normal priority. |

Off, deliberately:

| Setting | Why it is off |
| --- | --- |
| `PrivateTmp`, `ProtectSystem`, `ProtectHome`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `ReadOnlyPaths` | In a user unit each needs a user namespace. Where unprivileged user namespaces are turned off the runner would not start at all. `ProtectHome` and a strict `ProtectSystem` would also hide the runner directory, SDKs and caches in the home directory. `ReadOnlyPaths` on the toolkit would be the useful one, but a job can undo it through the user manager. |
| `PrivateDevices` | Hides `/dev/kvm`, which emulator jobs need. |
| `MemoryDenyWriteExecute` | Breaks JIT compilers: the JVM, Node.js, Android's tools. |
| `SystemCallArchitectures=native` | Breaks 32-bit tools still found in some SDKs. |
| `RestrictNamespaces` | Breaks browser and emulator sandboxes and rootless containers, which create namespaces. |
| `UMask` | Would change the modes of files jobs create. The toolkit's own state files are private regardless (`GRM_UMASK`, below). |
| `MemoryMax`, `TasksMax` | Depend on the builds; a wrong value kills a build halfway. Set them per unit with `systemctl --user edit` once you know the peak. |

The toolkit's state directory and files are created mode 700 and 600
(`GRM_UMASK`, default `077`), so other accounts cannot read the repository and
job names in them. Commands run by `with-device-lock` get the job's own umask
back. The mask applies to new files only: a state directory made before it
keeps its old modes until you run `chmod -R go-rwx` on it once (or the group
equivalent, `chmod -R o-rwx`, with `GRM_UMASK=007`).

## Separate accounts

By default every runner, the hooks, the state directory and the dashboard run
under one account. That account is the security boundary, so every job of
every attached repository can:

- read every runner's credentials (`.credentials`, `.runner`), its checkouts
  in `_work`, and the environment of other running jobs, secrets included;
- change the toolkit (`hooks/`, `lib/`, `bin/`), `config.env`, the runner's
  `.env` or any user unit, and so run code in every later job of every
  repository;
- read and change anything else the account owns: SSH keys, tokens, shell
  start-up files.

Slots, locks and the unit settings above do not change this. In order of
effect:

1. **Never run runners under your login account.** Create an account for
   them, with no SSH keys, no tokens, no `sudo`, and nothing in its home
   directory but the runners and the toolkit. This alone keeps a job away from
   everything else you own.
2. **Make the toolkit and its configuration read-only to that account.** Keep
   the checkout and `config.env` owned by another account (root, or your own)
   and readable by the runner account; point `GRM_CONFIG` at the file. Only
   the runner directories and `GRM_STATE_DIR` need to be writable. A job can
   then no longer rewrite the hooks, though it can still change its runner's
   `.env` and units.
3. **One account per runner, sharing a group for the state.** Jobs of one
   repository then cannot read another runner's credentials or checkouts.
   - Create a group for the runners and a state directory owned by it with
     mode 3770 (shared group, and only a file's owner may delete or rename
     it); set `GRM_STATE_DIR` to it and `GRM_UMASK=007` in the shared
     `config.env`, so lock and state files are shared with the group and no
     one else. The device lock must live there too.
   - The accounts still trust each other with the state. Any of them can
     rewrite the slot state, hold a lock, or replace a file it created with a
     link. The toolkit never truncates a lock file and never writes through a
     link at the log or holder paths, so this cannot damage another account's
     files, but it can stall or mislead the gate.
   - Keep each runner directory mode 700, owned by its account, and install
     its unit as that account (it needs lingering to start at boot).
   - Limits today: lock-holder detection sees only processes of the account
     it runs as. `grm-status` shows the device lock as free while another
     account holds it, and the stale-lock watchdog cannot see or clear a
     holder in another account. Slot bookkeeping reads other accounts'
     processes in `/proc`, so `/proc` must not be mounted with `hidepid`. The
     dashboard reads the state through `grm-status`, so run it as an account
     in the group.

What no account layout fixes is sharing between jobs of the same runner: see
[consumer-workflow.md](consumer-workflow.md#trust-between-jobs).
