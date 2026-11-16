# Consumer workflow

For a **private, trusted** consumer repository with two manually registered
runners: one labelled `emulator-pr` for pull requests, one labelled
`emulator-main` for the main branch. Read [trust between jobs](#trust-between-jobs)
for why there are two.

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
    # Only a push to main goes to the main runner; everything else, pull
    # requests included, to the pull-request runner. This routes honest jobs;
    # it does not stop a pull request that edits this line (see below).
    runs-on: [self-hosted, linux, "${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && 'emulator-main' || 'emulator-pr' }}"]
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
background device work beyond the wrapped command's lifetime.

## Trust between jobs

A runner here is persistent: the same registration, account and home directory
serve job after job, and nothing is cleaned in between. The workspace in
`_work`, tool caches (`~/.gradle`, `~/.m2`, `~/.npm` and the like), git hooks
and configuration, and any process a job leaves running all carry over. systemd
stops leftover processes only when the runner unit itself stops. So any job can
plant something that a later job runs, and a later job's secrets are only as
safe as the least trusted job before it.

- **Never attach these runners to a public repository**, and never let them run
  pull requests from forks. Forks of a public repository can run any code on
  the machine; for a private repository keep the setting that runs workflows
  from fork pull requests turned off. Public work, including this toolkit's own
  CI, belongs on GitHub-hosted runners.
- **Keep pull-request jobs off the runner that runs main-branch jobs.** A pull
  request is code nobody has reviewed yet: a contributor branch, an automated
  dependency bump, a package's install script. Give pull requests their own
  registration and label, as in the example, preferably under their own
  account ([separate accounts](runner-units.md#separate-accounts)): under one
  account the two runners still share the home directory and its caches.
- **Labels route jobs; they do not stop a pull-request author.** A
  `pull_request` job runs the workflow file from the pull request, so its
  author can change `runs-on` to the main runner's label. Only settings
  outside the repository hold against that: an organisation runner group
  restricted to the main branch's workflows, where your plan offers it, or no
  self-hosted runner for main-branch jobs at all. With repository-level
  runners, any collaborator who can open a pull request can reach every
  runner registered to the repository.
- **Keep secrets off self-hosted jobs.** Give the job `permissions: contents:
  read` and no secrets. Jobs that deploy or publish run on GitHub-hosted
  runners, after the self-hosted tests pass.
- **Clean up what you can.** Let `actions/checkout` clean the workspace (its
  default), avoid long-lived caches in the home directory for jobs that do not
  need them, and stop the processes a job starts before it ends.
- **Prefer one-job runners where you can.** A runner registered with
  `--ephemeral` takes one job and unregisters, so nothing carries over. It
  needs a fresh registration token for every job, which this toolkit does not
  handle; its units restart a runner that exits and suit long-lived ones only.
