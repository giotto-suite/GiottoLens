# 0025. Jobs run in one mirai daemon per viewer, which holds the object shown

- **Status:** Proposed
- **Date:** 2026-11-18
- **Supersedes:** —
- **Superseded by:** —

## Context

The httpuv server runs on R's main thread, so anything R computes for the page freezes the
viewer and the console for its duration. Three features needed a background process and had
each started their own: pulls (a one-worker mizu pool, reloading the snapshot per job),
gene colouring and region DE (a callr session holding the snapshot), and analysis mode (a
second callr session holding a step cache). Each loaded the object again, each had its own
notion of a job, and only the first could be listed or cancelled.

Loading is the cost. On the Atera section `loadGiotto()` of a snapshot takes about 12 s, of
which most is the R session's packages and the object's in-memory parts; one gene read on an
object already loaded is a small fraction of that. Analysis steps also need a running job to
stop when its parameters change.

## Decision

Each viewer has one mirai daemon (its own compute profile), started by the first job and
stopped by `close()`, with:

- **cleanup off**, so the daemon keeps the object it loaded. It loads the object shown from the
  project path and snapshot name, never from a serialized copy, and loads again only when the
  snapshot shown changes.
- **dispatcher on**, so `cancel_job()` interrupts a running job (`stop_mirai()`) and drops a
  queued one.
- **the project's vault as the artifact dump**, so anything a job writes is in the project and
  can be kept by a snapshot. There is no temp source.
- **arrow loaded before GiottoClass**, by `requireNamespace()` at daemon start, so store reads do
  not collide with GDAL over the `file` scheme.

A job is a function of the object, `fun(g, ...)`. Its result is applied on the main thread from
the later loop, through a promise, and only if the object shown is still the one it started
from. Every tab hears each job start and end as a `job` message, with progress when the job
reports it (`.lens_progress()`, through a file in the session folder, polled every 0.25 s).
`jobs()` lists running jobs and `cancel_job()` cancels one, from R or from the page (the
`cancel_job` ask).

Measured on a held daemon: a job's round trip is 12 ms; `stop_mirai()` interrupts a sleeping
job and a long R loop at once, and the held object is intact afterwards.

## Consequences

- The first job waits for the daemon to load its packages and the object (seconds; about 12 s
  for the Atera section). Later jobs on the same object start at once.
- One daemon means one queue: a long job delays the next. A second, warm daemon for short reads
  is the way out if that matters, at the cost of a second copy of the object.
- Compiled code may not stop until its current call returns, so a cancel can take that long.
- The daemon runs installed packages only. A job's `fun` runs there as a plain function and
  calls other packages by `pkg::`.
- Progress goes through a file, so a remote daemon needs another channel; the job interface
  does not change for it.

## Alternatives considered

- **A mizu pool** (the pull's first form). Cancelling never interrupts a running task, it is
  for one machine only, and it was new (0.1.0); its zero-copy results matter little when the
  cost is the load.
- **A callr session** (gene colouring, analysis). It interrupts, but it is polled and cannot be
  remote.
- **A load per job.** Simple, but every job pays the load.
- **The object serialized to the daemon** (`saveRDS()` and read back). A second copy on disk,
  and a gzip RDS of the Atera object takes 5.4 s to write.
- **Forking a warm process** to copy its loaded state. arrow's and GDAL's thread pools make
  fork unsafe, and there is no fork on Windows.

## References

`R/jobs.R`, `R/viewer.R` (`start_job()`, `run_job()`, `jobs()`, `cancel_job()`),
`tests/testthat/test-jobs.R`.
