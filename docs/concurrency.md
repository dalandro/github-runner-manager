# Cancel superseded runs

Use workflow-level concurrency to avoid building obsolete commits:

```yaml
concurrency:
  group: tests-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Only the newest pending run for a group is retained; a new queued run replaces
the older pending run. Do not assume FIFO ordering from GitHub concurrency.
Groups coordinate within a repository only, so they cannot replace host-wide
slots or device locks shared across repositories.

For workflows that also deploy, cancel only pull requests:

```yaml
concurrency:
  group: checks-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
```

Choose groups to match deployment safety; do not cancel an in-progress deployment
without understanding its recovery. Cancellation is cooperative: child commands
need shutdown handling. The device wrapper retains its lock through immediate
child termination, but SIGKILL of the wrapper is still a known gap.
