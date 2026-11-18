# Jobs run in the viewer's mirai daemon, which keeps the object shown loaded
# between them (R/jobs.R, adr/0025).

jobs_viewer <- function() {
    fx <- lens_bins_fixture()
    v <- suppressMessages(launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE))
    list(v = v, priv = get("private", v$.__enclos_env__))
}

test_that("a job runs over the object shown, loaded once by the daemon", {
    jv <- jobs_viewer()
    on.exit(jv$v$close(), add = TRUE)
    priv <- jv$priv
    n <- priv$run_job("t", "count", function(g) length(GiottoClass::spatIDs(g, spat_unit = "bin")),
        apply = function(x) x * 2L)
    expect_identical(n, 1800L)
    addr <- function() priv$run_job("t", "address", function(g) rlang::obj_address(g))
    a <- addr()
    expect_identical(addr(), a)
    # Writes go to the project's vault, not a temp source
    dump <- priv$run_job("t", "dump", function(g) GiottoDisk::getArtifactDumpDir())
    expect_identical(normalizePath(dump), normalizePath(file.path(priv$project@path, "artifacts")))

    expect_error(priv$run_job("t", "boom", function(g) stop("boom!")), "\\[t\\] boom error: boom!")
    expect_length(jv$v$jobs()$id, 0L)
})

test_that("a running job is interrupted by a cancel, and the daemon keeps its object", {
    jv <- jobs_viewer()
    on.exit(jv$v$close(), add = TRUE)
    priv <- jv$priv
    a <- priv$run_job("t", "address", function(g) rlang::obj_address(g))
    end <- NULL
    applied <- FALSE
    id <- priv$start_job("sleep", function(g) { Sys.sleep(30); 1 },
        apply = function(x) applied <<- TRUE, on_end = function(r) end <<- r)
    expect_identical(jv$v$jobs()$label, "sleep")
    later::run_now(0.5)
    t0 <- Sys.time()
    expect_true(jv$v$cancel_job(id))
    expect_true(pump_until(function() !is.null(end), timeout = 10))
    expect_lt(as.numeric(Sys.time() - t0, units = "secs"), 5)
    expect_identical(end$state, "cancelled")
    expect_false(applied)
    expect_false(jv$v$cancel_job(id))
    expect_identical(priv$run_job("t", "address", function(g) rlang::obj_address(g)), a)
})

test_that("a result is dropped once the object shown changes", {
    jv <- jobs_viewer()
    on.exit(jv$v$close(), add = TRUE)
    priv <- jv$priv
    end <- NULL
    applied <- FALSE
    priv$start_job("wait", function(g) { Sys.sleep(1); 1 },
        apply = function(x) applied <<- TRUE, on_end = function(r) end <<- r)
    priv$load_seq <- priv$load_seq + 1L
    expect_true(pump_until(function() !is.null(end), timeout = 30))
    expect_identical(end$state, "cancelled")
    expect_identical(end$message, "the object shown changed")
    expect_false(applied)
})

test_that("the page hears of jobs and their progress, and can cancel one", {
    testthat::skip_if_not_installed("websocket")
    jv <- jobs_viewer()
    on.exit(jv$v$close(), add = TRUE)
    priv <- jv$priv
    a <- ws_client(ws_url(jv$v), load = priv$load_seq)
    on.exit(a$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() jv$v$connected()))
    jobs_heard <- function() Filter(function(m) m$type == "job", a$state$msgs)

    end <- NULL
    priv$start_job("steps", function(g) {
        for (i in 1:4) { .lens_progress(i, 4, "step"); Sys.sleep(0.4) }
        TRUE
    }, ref = "p1", progress = TRUE, on_end = function(r) end <<- r)
    expect_true(pump_until(function() !is.null(end), timeout = 60))
    expect_identical(end$state, "done")
    expect_true(pump_until(function() any(vapply(jobs_heard(), function(m) identical(m$data$state, "done"), NA))))
    heard <- jobs_heard()
    expect_true(all(vapply(heard, function(m) identical(m$data$ref, "p1"), NA)))
    prog <- Filter(Negate(is.null), lapply(heard, function(m) m$data$progress))
    expect_gte(length(prog), 2L)
    expect_identical(prog[[length(prog)]]$total, 4L)
    expect_false(file.exists(file.path(priv$session, "jobs", "1.progress")))

    # A cancel from the page
    id <- priv$start_job("sleep", function(g) { Sys.sleep(30); 1 }, on_end = function(r) end <<- r)
    later::run_now(0.3)
    # A page that connects while it runs hears of it
    b <- ws_client(ws_url(jv$v), load = priv$load_seq)
    on.exit(b$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() any(vapply(b$state$msgs, function(m)
        m$type == "job" && identical(m$data$id, id) && identical(m$data$state, "running"), NA))))
    hit <- Find(function(m) m$type == "job", b$state$msgs)
    expect_true(is.numeric(hit$data$started))
    a$ws$send(jsonlite::toJSON(list(type = "ask", id = "c1", data = list(op = "cancel_job", id = id)),
        auto_unbox = TRUE))
    expect_true(pump_until(function() identical(end$state, "cancelled"), timeout = 10))
    ans <- Find(function(m) m$type == "answer" && identical(m$data$id, "c1"), a$state$msgs)
    expect_true(ans$data$data$cancelled)
})

test_that("jobs need an object from a snapshot, and close() stops the daemon", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(get("private", v$.__enclos_env__)$start_job("x", function(g) 1),
        "jobs need an object shown from a snapshot")

    jv <- jobs_viewer()
    priv <- jv$priv
    priv$run_job("t", "start", function(g) TRUE)
    profile <- priv$job_profile
    expect_true(is.character(profile))
    suppressMessages(jv$v$close())
    expect_null(priv$job_profile)
    expect_identical(as.integer(mirai::status(.compute = profile)$connections), 0L)
})
