# 0034. What the page asks R to do reports to the page, not the console

- **Status:** Proposed
- **Date:** 2026-11-24
- **Supersedes:** —
- **Superseded by:** —

## Context

R handles every message the page sends on its main thread. Errors, warnings and messages
raised while it does went to the R console: a warning per handler (`set_column_type`,
`preferences_set`, the analysis's messages), and plain `warning()` and `message()` calls
deeper down (a pull's "pulled N column(s)", `.write_metadata()`'s column warnings, a missing
cell ID). Some went only to the log (`viewer$log()`): a volcano pick whose gene could not be
read, an autosave failure, which was logged every second while it lasted. The page showed an
error in three places of its own: the jobs popover, an analysis step, and the images panel's
"add image". Whoever clicked was looking at the page, often in an IDE pane beside a console
they were not watching, and saw nothing.

## Decision

What the page asks R to do reports to the page only. R handles each page message inside
`for_page(where, expr)` (private, `R/viewer.R`), which collects the action's warnings and
messages (muffled) and its error (which ends the action) and logs them as one entry at the
most severe level: `error`, `warning` or `message`, with `where`, `message` and every item.
Every log entry goes to the page (`log_entry`), and the whole log to a tab on `ready`
(`log_entries`). A job started inside `for_page()` reports to the page again when it ends,
under its label. Calls made from R (`viewer$pull()`, `viewer$set_column_type()`) report to
the console as before.

The page shows the newest notice in place of the status line (an error until it is read, a
warning or message for a few seconds) and the log in a drawer that slides up over the
panels from the bottom bar's log button, with an unread count on the button.

## Consequences

- An action's conditions are one entry however many there are (at most
  `.lens_notice_items`, then a count), so a burst does not flood the page.
- The console no longer hears of the page's actions. `viewer$log()` is the R-side record.
- New code reports problems with plain `stop()`, `warning()` and `message()`; never a
  `tryCatch()` that also warns to the console. A handler that has to go on after an error
  reports it with `private$report()`.
- Work deferred with `later::later()` from a handler is outside `for_page()`: wrap it
  (`choose_image`), or it reports to the console.
- The protocol warning on `ready` (an old bundle) stays in the console: the fix is in R.
- Messages for whoever is at the R console about what the page did there (the viewer opened
  another snapshot or a save, the viewer moved to another window) stay in the console:
  `.console_message()` raises them with a class `for_page()` lets through.
- The analysis's own poll loop is not a page message and is not wrapped; its step errors
  show in the Analysis panel.

## Alternatives considered

- **Both the page and the console** — rejected by the maintainer: the console copy is noise
  for the person in the page, and `viewer$log()` keeps the record in R.
- **Toasts, stacked** — a burst would stack them; one slot on the status line and the log
  behind it holds any number.
- **A second bottom bar, or a popover from the tools rail** — the selection bar already has
  the status line, and a second bar takes height from short IDE panes.

## References

`R/viewer.R` (`for_page()`, `report()`, `log_notice()`, `add_log()`, `start_job()`),
`inst/viewer-src/ui/log.ts`, `tests/testthat/test-notices.R`, `tests/testthat/test-e2e-log.R`.
