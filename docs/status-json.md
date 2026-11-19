# Status as JSON

`grm-status --json` prints one JSON document describing everything the gates
know right now. It is the only seam between the Bash tools and any other view:
the [dashboard](dashboard.md) reads this document and nothing else. The command
is read-only: it creates no state, takes the slot state lock only as long as a
read needs, never probes the device lock with flock, and never signals a
process, whatever the watchdog's kill setting.

`grm-status --json --public` prints the same document filtered for a copy
that leaves this machine, such as a [relay push](relay-push.md); see
[public output](#public-output).

`grm-status --watch [seconds]` repeats the plain text view in the terminal
(default every 2 seconds) for hosts where a browser view is not wanted.

## Schema version 1

```json
{
  "schema": 1,
  "generated_at": 1767268800,
  "host": {"cpus": 6, "load_1m": 4.31, "max_load": 6, "memory_available_mb": 5270, "min_memory_mb": 3072},
  "runners": [
    {"name": "web-app", "repository": "org/web-app", "units": 2, "labels": "self-hosted,linux",
     "unit": "grm-runner-web-app.service", "unit_state": "active", "worker_pid": 52877}
  ],
  "workers": [
    {"pid": 52877, "directory": "/srv/runners/web-app"}
  ],
  "slots": {
    "capacity": 6, "used": 5, "max_wait_seconds": 2700,
    "records": [
      {"kind": "holding", "ticket": 41, "holder_pid": 52877, "units": 2, "label": "org/web-app",
       "since": 1767268606, "unparking": false,
       "job": {"repository": "org/web-app", "workflow": "CI", "job": "test", "run_id": "8123460345",
               "run_attempt": 1, "ref": "refs/pull/7/merge", "head_ref": "feature/x",
               "sha": "5c1d8e2fa907b34e6d1c0a8f2b9e7d4c3a6f1e05", "event": "pull_request",
               "actor": "dev-alex", "runner": "web-app", "server_url": "https://github.com",
               "pull_request": 7, "pull_request_title": "Add the thing", "queued_at": 1767268601}}
    ]
  },
  "device_lock": {
    "state": "held",
    "holder": {"repository": "org/mobile-app", "run_id": "8123456789", "job": "e2e-android",
               "pid": 51644, "since": 1767268145, "alive": true},
    "watchdog": {"min_age_seconds": 600, "kill": false,
                 "stale": [{"pid": 50112, "fd": 17, "age_seconds": 1840, "command": "adb"}]}
  },
  "events": [
    {"at": 1767268606, "kind": "admit", "subject": "org/web-app", "detail": "ticket 41, 2 units after 0s; used 5/6"}
  ]
}
```

| Field | Meaning |
| --- | --- |
| `schema` | Integer version. Additive changes keep the number; a removed or re-typed field raises it. Readers must reject versions they do not know. |
| `generated_at` | Epoch seconds when the document was produced. All other times are epoch seconds too. |
| Numbers | Integers are whole and from 0 to 2^53 - 1; `load_1m` and `max_load` are 0 or from 0.01 to 1,000,000. The dashboard rejects a document outside these bounds rather than render it. |
| `host.load_1m`, `host.memory_available_mb` | Current readings; `null` when unavailable. `max_load` and `min_memory_mb` are the host's default `wait-for-load` thresholds (`GRM_MAX_LOAD`, `GRM_MIN_MEM_MB`): the gate passes when load is below the first and memory at or above the second. A step that passes `--max-load` or `--min-mem-mb` waits on its own values, which the document does not show. |
| `runners[]` | One entry per `GRM_RUNNERS` line, in configuration order. `unit_state` is the first word `systemctl is-active` prints (`active`, `inactive`, `failed`, ...) or `unknown`. `worker_pid` is the job worker process whose executable lives in that runner's directory, or `null` when the runner is idle. |
| `workers[]` | Every busy job worker owned by the current user, including runners outside `GRM_RUNNERS`. `pid` is its process id; `directory` is the executable path with its last two components removed (`/srv/runners/web-app/bin/Runner.Worker` becomes `/srv/runners/web-app`, also for `bin.<version>`). Older producers may omit this array; readers treat it as empty. |
| `slots.records[]` | Live records after in-memory reaping, in state-file order. `kind` is `holding`, `queued` or `parked`; queue order is ascending `ticket`. `holder_pid` equals a runner's `worker_pid` when the job came through the runner hooks. `since` is the last transition (`null` for records older than the field). `unparking` is true while a parked job is actively asking for its units back. |
| `slots.records[].job` | What the job's start hook recorded ([job records](job-slots.md#job-records)). Always an object with these keys; a field the record lacks is `null`, and all are `null` for a holder without a record. `run_id` is a string, `run_attempt`, `pull_request` and `queued_at` (epoch seconds, when the start hook ran) are numbers. Older producers omit `job`; readers treat a missing or `null` object, or a missing key, as unknown. Strings are ASCII: any other character reads `?`, as everywhere in this document. |
| `device_lock.state` | `absent` (no file at the configured lock path), `free` or `held`, from the lock's flock holders. |
| `device_lock.holder` | The wrapper's holder file, or `null`. `alive` says whether that wrapper process still exists; a `held` lock without a live holder is a leaked descriptor. |
| `device_lock.watchdog.stale[]` | What `stale-lock-watchdog` would report now: flock holders other than the live wrapper, older than `min_age_seconds`. `kill` reports the configured mode only. |
| `events[]` | The newest 50 lines of the [event log](events.md), oldest first. |

Strings are ASCII: any other byte, and any control character, is written as
`?`. Numbers that cannot be read are `null`, never a string.

The bundled demo document, `dashboard/priv/demo/status.json`, is checked by the
suite to have exactly the key shape of real output, so the demo cannot drift
from the schema.

## Public output

`--public` is an allow-list. Every field above has a class in
[`lib/public.sh`](../lib/public.sh), and the document keeps its key shape and
schema, so the dashboard reads it unchanged. A field without a class stops the
output (exit 70), and the suite fails until a new field gets one.

| Class | Fields | Sent |
| --- | --- | --- |
| keep | numbers, states, times, process ids, the stale holder's process name (the kernel's short name of the process holding the device lock, such as `adb`; also the subject of `stale` and `kill` events), event kinds | as is |
| alias | runner names (`runner-1`, `runner-2` in config order) and units (`runner-1.service`); repositories, slot labels, the lock holder's repository and event subjects (`repo-1`, `repo-2` in config order); a job's runner | the stand-in, or `other` for a name the config does not list |
| share | the job details: workflow, job, run id and attempt, ref, head ref, sha, event, server URL, pull request number and title; the lock holder's run id and job | `null`, or `""` where the schema needs a string |
| numeric | event detail | only in the numeric forms the gates write (`ticket 41, 2 units after 0s; used 5/6`), else `""` |
| never | worker directories (the runner's alias instead), runner labels, the job's actor | never |

`GRM_RELAY_SHARE_DETAILS=1` in the config is the one opt-in: alias, share and
numeric fields are then sent as they are, so the board shows real repository
and runner names and links to each job's run and pull request. Paths, runner
labels and user names stay out either way.
