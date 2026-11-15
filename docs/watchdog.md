# Stale device lock watchdog

`stale-lock-watchdog [--lock FILE] [--min-age S] [--kill]` scans current-user
process fd symlinks for the lock inode and checks their fdinfo for `lock:` FLOCK
entries. `/proc/locks` can show nothing after the original flock process exits;
fdinfo follows the open file description and exposes the inherited lock.
Opening the file without a lock is not a finding.

The holder-file wrapper PID is legitimate only if alive with matching start ticks.
Other processes holding the lock become stale once their **process age** reaches
`GRM_WATCHDOG_MIN_AGE`. Age is system uptime minus process start ticks divided by
`getconf CLK_TCK`, equivalent to using boot epoch (`btime`) and current epoch.
This estimates process age, not duration of lock ownership.

Each stale descriptor is reported with PID, comm, age, fd, and recorded holder.
Missing/dead holder metadata gets an additional diagnostic. Exit 1 means findings;
0 means clean. Default is report-only. `--kill` or `GRM_WATCHDOG_KILL=1` permits
TERM only for exact space-separated comm entries in `GRM_WATCHDOG_KILL_ALLOW`.
The default allow-list is empty; kill mode then kills nothing and says so.
Other processes are explicitly reported as not killed. PID identity is rechecked
before signalling, but process inspection and signalling remain inherently racy.

Install the rendered oneshot and five-minute persistent timer with
`grm-install-runner --watchdog repo-a`. Review the user journal; exit 1 is accepted
by the unit so findings do not mark it failed. The timer stays installed when an
individual runner is removed. To remove the shared timer, stop/disable it, remove
both watchdog units from the configured user-unit directory, and reload the user
manager. A process with an unopened/inaccessible fd, another user's process,
or a surviving command without a lock is outside this detector. Comm names are
not a security boundary; keep kill mode off until observations justify it.
