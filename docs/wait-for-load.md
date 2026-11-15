# Load and memory wait

Call `wait-for-load` before a heavy build. It requires 1-minute load strictly less
than `--max-load L` and `MemAvailable` at least `--min-mem-mb M`. Memory values
labelled MB are MiB, using 1024 kB. Linux load includes runnable and uninterruptible
work; it is a coarse admission signal.

`--timeout S` defaults to the configured load timeout. `--interval S` defaults to
15 seconds, with up to two seconds of jitter for intervals of at least a second.
Fractional/zero intervals are useful for tests; avoid busy polling in workflows.
Missing or malformed metrics are treated as unavailable, never as idle.

`--on-timeout proceed` warns and succeeds by default, preserving forward progress.
Use `--on-timeout fail` to exit 1 instead. Invalid options/configuration exit 2.
A passing snapshot reserves nothing: simultaneous callers can all pass, and load
averages lag activity. Combine with slots; this is not a memory limit or OOM
prevention guarantee. The wait does not park slots, since it is not waiting on
another gated job's exclusive device lock.
