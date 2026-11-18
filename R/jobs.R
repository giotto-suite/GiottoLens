# Jobs (adr/0025): work the viewer runs in a background R process, so R's
# main thread keeps serving the page and the console stays free. Each viewer
# has one mirai daemon of its own (a compute profile named for it), started by
# the first job and stopped by close(). Dispatcher is on, so a running job can
# be interrupted; cleanup is off, so the daemon keeps what it loaded between
# jobs: the object shown, read from the project path and snapshot name, and
# read again only when those change. Anything a job writes goes to that
# project's vault, never to a temp source. A job is a function of the object,
# `fun(g, ...)`; its result is applied on the main thread from the later loop.
#
# The daemon loads installed packages only, never a development copy of this
# one: the functions below run there as plain functions (`.job_fun()`), and a
# job's `fun` must call other packages by `pkg::`.

# Packages the daemon loads before anything else: arrow before GDAL (terra,
# through GiottoClass), or the two collide over the 'file' filesystem scheme
# and store reads fail ("features not found" from spatValues())
.job_packages <- c("arrow", "GiottoDisk", "GiottoClass")

# `f` without its package environment, so it runs on the daemon unchanged
.job_fun <- function(f) {
    environment(f) <- globalenv()
    f
}

# ── Daemon side (plain functions, assigned in the daemon's global env) ──────

# The object shown, loaded once per project path and snapshot name. What it
# writes goes to the project's vault.
.jw_object <- function(path, name) {
    w <- get0(".lens_w", envir = globalenv(), inherits = FALSE)
    if (!is.null(w) && identical(w$path, path) && identical(w$name, name)) return(w$g)
    assign(".lens_w", NULL, envir = globalenv())
    g <- suppressMessages(GiottoClass::loadGiotto(path, name = name, verbose = FALSE))
    if (inherits(g@source, "gDirSource"))
        GiottoDisk::setArtifactDumpDir(g@source, verbose = FALSE)
    assign(".lens_w", list(path = path, name = name, g = g), envir = globalenv())
    g
}

# One job: `fun(g, ...)` over the object shown, `progress` the file
# .lens_progress() writes to (NULL: none)
.jw_run <- function(fun, args, path, name, progress) {
    assign(".lens_progress_file", progress, envir = globalenv())
    on.exit(assign(".lens_progress_file", NULL, envir = globalenv()), add = TRUE)
    do.call(fun, c(list(.jw_object(path, name)), args))
}

# For a job's `fun`: report how far it is, at most every 0.25 s (and always at
# the end). The viewer reads it and tells the page.
.lens_progress <- function(done, total, what = "") {
    f <- get0(".lens_progress_file", envir = globalenv(), inherits = FALSE)
    if (is.null(f)) return(invisible())
    now <- proc.time()[["elapsed"]]
    last <- get0(".lens_progress_t", envir = globalenv(), inherits = FALSE) %||% -Inf
    if (now - last < 0.25 && done < total) return(invisible())
    assign(".lens_progress_t", now, envir = globalenv())
    tmp <- paste0(f, ".tmp")
    writeLines(paste(as.numeric(done), as.numeric(total), what, sep = "\t"), tmp)
    file.rename(tmp, f)
    invisible()
}

# ── Main side ───────────────────────────────────────────────────────────────

# Start the daemon for compute profile `profile` and set it up
.job_daemon <- function(profile) {
    mirai::daemons(1L, dispatcher = TRUE, cleanup = FALSE, .compute = profile)
    helpers <- lapply(list(.jw_object = .jw_object, .jw_run = .jw_run,
        .lens_progress = .lens_progress, `%||%` = function(x, y) if (is.null(x)) y else x),
        .job_fun)
    mirai::everywhere({
        for (p in pkgs) requireNamespace(p, quietly = TRUE)
        options(giotto.use_conda = FALSE, giotto.check_core = FALSE)
        for (n in names(helpers)) assign(n, helpers[[n]], envir = globalenv())
    }, .args = list(pkgs = .job_packages, helpers = helpers), .compute = profile)
    invisible(profile)
}

.job_stop_daemon <- function(profile) {
    if (!is.null(profile)) try(mirai::daemons(0L, .compute = profile), silent = TRUE)
}

# A job's error as its message: mirai gives it as printed ("Error in f(): ...")
.job_error_text <- function(e) sub("^Error( in [^:]*)?: *", "", trimws(conditionMessage(e)))

# An ask's answer from a job's end (start_job()'s `on_end`): its result
# through `data`, or its message with code "cancelled" for a cancelled one
.job_answer <- function(r, data = identity) {
    switch(r$state,
        done      = list(data = data(r$result)),
        cancelled = list(error = r$message %||% "cancelled", code = "cancelled"),
        list(error = r$message))
}

# A progress file's line as list(done, total, what), or NULL
.read_progress <- function(file) {
    if (is.null(file) || !file.exists(file)) return(NULL)
    p <- tryCatch(strsplit(readLines(file, n = 1L, warn = FALSE), "\t", fixed = TRUE)[[1L]],
        error = function(e) NULL)
    if (length(p) < 2L) return(NULL)
    list(done = as.numeric(p[[1L]]), total = as.numeric(p[[2L]]),
        what = if (length(p) > 2L) p[[3L]] else "")
}
