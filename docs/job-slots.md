# Job slots

`job-slots acquire --units N --holder PID --label org/repo-a` queues a weighted
request. Hooks select the `Runner.Worker` ancestor; manual calls default to the
parent PID. `release`, `park`, and `unpark` accept `--holder PID`. Hook scripts
resolve symlinks to their installation before calling the gate.

A short flock protects `slots/state`. Updates use a temporary file and atomic
rename. No lock is held during sleep. Tickets increase monotonically; queued
requests enter in ticket order, even when a smaller request could fit first.
Holding weights count against capacity. Oversized requests can enter alone.
Default capacity is 6 units; `GRM_SLOTS_MAX_WAIT` defaults to 2700 seconds.
A waiting job's log says so at once and every 30 seconds, with its ticket, the
units in use and how many other jobs are in the gate, never their names.
Each step takes the state lock for a moment only. If another process keeps it
for `GRM_LOCK_WAIT` seconds (default 30), the command gives up with exit 75
instead of stalling every runner's hook: the job fails to start, or its units
are left for reaping. The status view skips the event list after one second
for the same reason.

```text
kind ticket holder-pid holder-start waiter-pid waiter-start units label since
```

`since` is the epoch second of the record's last transition (queued, admitted,
parked, or asking for parked units back); the status views derive wait and hold times from it. Records written
before the field existed read as 0, shown as unknown.

Every field is checked for its exact shape before use: numbers are plain
unsigned integers, the kind is one of three words, the label uses the label
alphabet below. Bash evaluates a variable's value in arithmetic, so an unchecked
field such as `next[$(command)]` would run the command in every gate and status
call. A line that does not match is dropped as corrupt: status commands skip it,
the next writing call removes it, prints a warning and logs a `corrupt` event.
The next ticket is always above every ticket in use, even when the header is
damaged.

The `next N` header records the next ticket. Labels replace characters outside
`[A-Za-z0-9._/:-]` with underscores. `status --raw` prints records after reaping
in memory; neither status mode writes state. Normal status includes capacity,
used units, holders, parked requests, and the queue.

Every locked operation reaps dead holders by PID and Linux start ticks, guarding
PID reuse. Queued records also require a live matching waiter. Zombies count as
dead. `/proc/<pid>/stat` is split after its last `)` because comm can contain
spaces and parentheses. Identity always uses the real process filesystem.

Parking returns units while retaining the original ticket. A parked job does not
block the queue until it requests unpark. Active unpark requests precede queued
jobs and use original ticket order among themselves. Waiter fields identify
active unpark requests too; a killed unpark waiter leaves a parked record without
blocking admissions. No record makes park/unpark a successful no-op.
While unparking, the device holder keeps the device lock idle until its units fit
again, bounded by `GRM_SLOTS_MAX_WAIT`.

The device-lock deadlock argument: every job waiting for the device holds no
units. The lock holder waits only for units held by running jobs that are not
waiting for the device, so those jobs can finish. This assumes every device user
uses parking consistently and takes no additional locks in conflicting order.

After `GRM_SLOTS_MAX_WAIT`, acquire/unpark warns and admits despite capacity or
queue priority. Overcommit remains visible. Notices describe admission and, every
30 seconds of waiting, current records. There is no time-based expiry or daemon.
The guarantee is accounting, not hard quotas; a stuck live holder remains until
it exits or the operator releases it. Reboot clears process identities; do not
share state between machines. Exit 2 means usage/configuration error.

## Job records

The start hook also writes what the runner tells it about the job to
`$GRM_STATE_DIR/jobs/<holder-pid>`, for the status views: one `key value` line
per field the job has, from the runner's variables (`GITHUB_REPOSITORY`,
`GITHUB_WORKFLOW`, `GITHUB_JOB`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`,
`GITHUB_REF`, `GITHUB_HEAD_REF`, `GITHUB_SHA`, `GITHUB_EVENT_NAME`,
`GITHUB_ACTOR`, `RUNNER_NAME`, `GITHUB_SERVER_URL`), plus the pull request
number and title from the event payload (`GITHUB_EVENT_PATH`) when `python3` is
installed. Nothing is fetched over the network.

```text
start 18232718
queued_at 1767268692
repository org/repo-a
workflow CI
ref refs/pull/7/merge
pull_request 7
pull_request_title Add the thing
```

The first line is the holder's start ticks, so a record never passes to a later
process with the same pid; `queued_at` is when the hook ran. Values lose control
characters and are cut at 256 characters. The file is written aside and renamed
over, with the state directory's permissions. The completion hook deletes it,
and every start hook deletes records whose process is gone. Writing is best
effort: a record that cannot be written never fails the job. `grm-status` only
reads them; job records are diagnostic metadata, not proof of identity.

Records appear for jobs that start after the hooks are updated; jobs admitted
earlier, and holders outside the hooks (`job-slots acquire` by hand), have none
and show as unknown.
