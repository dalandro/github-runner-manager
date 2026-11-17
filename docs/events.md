# Event log

The gates append one line per transition to `$GRM_STATE_DIR/events.log` so the
status views can show what happened recently, not only what is true now.

```text
epoch kind subject detail...
```

| Kind | Written by | Meaning |
| --- | --- | --- |
| `queue` | `job-slots acquire` | A request took a ticket. |
| `admit` | `job-slots acquire`, `unpark` | Units granted; detail has the wait. |
| `overcommit` | `job-slots acquire`, `unpark` | Admitted after `GRM_SLOTS_MAX_WAIT` despite capacity or order. |
| `park` / `unpark` | `job-slots` | Units returned while waiting for the device; units requested back. |
| `release` | `job-slots release` | A holder gave its units back. |
| `reap` | any writing `job-slots` call | A record's process was gone and the record was dropped. |
| `corrupt` | any writing `job-slots` call | State lines that were not exactly a valid record were dropped (count only; the content is never logged or evaluated). |
| `lock-wait` / `lock-acquire` / `lock-release` / `lock-timeout` | `with-device-lock` | Device lock life cycle. |
| `stale` / `kill` | `stale-lock-watchdog` | A stale lock holder was found (logged once per holder, however often the watchdog runs); TERM was sent. |

The subject is the slot label or repository; whitespace in it becomes `_`.

The log is advisory. Writing is best effort and never fails a gate. A gate waits
at most one second for `events.lock` and then drops the event; a full disk loses events, not jobs. It is
bounded: once it exceeds twice `GRM_EVENTS_MAX` lines (default 500) it is cut
back to the newest `GRM_EVENTS_MAX`, in place and under the same lock, so the
file is never replaced under a reader. `GRM_EVENTS_MAX=0` turns it off. Status
commands only read it; a reap seen by `status` is not logged because status
never writes.
