# Consumer workflow

For a **private, trusted** consumer repository whose manually registered runner
has the emulator label:

```yaml
name: tests
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
concurrency:
  group: tests-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  emulator:
    runs-on: [self-hosted, linux, emulator]
    timeout-minutes: 75
    steps:
      - uses: actions/checkout@v4
      - name: Build when host has headroom
        shell: bash
        run: |
          "$HOME/github-runner-manager/bin/wait-for-load" --on-timeout fail
          ./scripts/build.sh
      - name: Emulator tests
        shell: bash
        run: |
          GRM_HOME="$HOME/github-runner-manager"
          exec "$GRM_HOME/bin/with-device-lock" -- ./scripts/run-emulator-tests.sh
```

Runner hooks apply the job-slot gate before steps start and release units at job
completion. Do not acquire the gate again from the workflow. The weight belongs
to the runner configuration, not an individual workflow step. Use separate runner
registrations if jobs need different fixed weights.

Only device-dependent steps take the device lock. Busy device waits return slot
units, then restore them before running. Load waits can fail, and device waits
fail after their configured timeout; ensure the job timeout leaves time for
cleanup. The wrapper forwards the signal it receives unchanged (INT, TERM or
HUP), so scripts should trap all three and stop their own descendants; run long
commands as `cmd & wait $!` so Bash traps fire promptly. Do not
background device work beyond the wrapped command's lifetime. Public pull
requests must use GitHub-hosted runners, including this toolkit's own CI.
