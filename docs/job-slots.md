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

```text
kind ticket holder-pid holder-start waiter-pid waiter-start units label since
```

`since` is the epoch second of the record's last transition (queued, admitted,
or parked); the status views derive wait and hold times from it. Records written
before the field existed read as 0, shown as unknown.

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
