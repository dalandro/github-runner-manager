# Device lock

`with-device-lock [--lock FILE] [--timeout S] -- command args...` serialises use
of one emulator/device. The default `GRM_DEVICE_LOCK_TIMEOUT` is 3600 seconds.
Its timeout exits 75 and names the recorded holder.
Busy waits announce that holder. The holder file records repository, workflow
run identifier, job, wrapper PID, start ticks, and acquisition epoch seconds.
It is diagnostic metadata, not proof of ownership.

If a script takes a lock on a file descriptor and then starts a tool that forks
a long-lived daemon, the daemon inherits the descriptor and the lock with it;
the lock then lives as long as the daemon. The wrapper owns a named descriptor
and closes it in the command before exec. Descendants cannot inherit it.
Only the wrapper retains it while the command runs.

`flock -w ... -E 75` runs in the background and the shell waits, so traps remain
responsive during acquisition. Do not replace the run stage with `flock -o lock
command`: flock's command mode closes the child's fd but does not forward TERM
or INT. It can die and release the lock while the command is still shutting down.

TERM, INT, and HUP cancel the wrapper. It forwards the received signal
unchanged to flock while waiting or to the immediate child while running, re-waits
across interrupted waits, and kills that child after `GRM_DEVICE_LOCK_GRACE` if
necessary. Commands start with INT and QUIT restored to their default dispositions. Stdin and normal
exit status pass through. Commands must shut down their own descendants.
The wrapper exits 128 plus the cancelling signal and removes its holder file.

In workflow steps, use `exec "$GRM_HOME/bin/with-device-lock" -- command` as the
last command. The runner signals the step shell; `exec` replaces that shell so
cancellation reaches the wrapper. The default `GRM_DEVICE_LOCK_GRACE` is 5 seconds.
Keep it short: on cancellation the runner escalates on its own within seconds;
exact timings vary by runner version. This path is not verified on a real runner.

If the lock is initially busy, the wrapper parks its worker's slots, then
unparks after acquiring, before running the command. Set `GRM_SLOTS_HOLDER` to a
live holder PID outside runner jobs, or `GRM_DEVICE_LOCK_PARK=0` to disable.
A free lock does not park. Cancellation/timeout while parked leaves the record
parked until job completion or holder reaping; it does not block other jobs.

SIGKILL of the wrapper drops the lock while its command may continue. Runner
orphan cleanup and the watchdog help, but cannot eliminate this limitation.
A watchdog detects leaked descriptors, not unlocked surviving commands. Never
unlink a live lock file. All device users must cooperate on the same local path.
