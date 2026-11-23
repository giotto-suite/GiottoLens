# How launch_lens() opens the viewer: the IDE's pane or a browser, and the
# launch page a command gets

# ── Where the viewer opens ───────────────────────────────────────────────────

test_that("the viewer opens in RStudio's pane, else the browser", {
    opened <- NULL
    pane <- function(url) opened <<- url
    local_browse <- function(url) opened <<- paste("browser:", url)
    old <- options(browser = local_browse, GiottoLens.viewer = NULL)
    on.exit(options(old), add = TRUE)

    expect_identical(.open_viewer("u", ide = "rstudio", pane = pane), "pane")
    expect_identical(opened, "u")
    expect_identical(.open_viewer("u", ide = "rstudio-server", pane = pane), "pane")
    expect_identical(.open_viewer("u", ide = "positron", pane = pane), "browser")
    expect_identical(.open_viewer("u", ide = "none", pane = pane), "browser")
    expect_identical(.open_viewer("u", ide = "rstudio", pane = NULL), "browser")
    options(GiottoLens.viewer = "browser")
    expect_identical(.open_viewer("u", ide = "rstudio", pane = pane), "browser")
    expect_identical(opened, "browser: u")
    # Positron's browseURL() shows its pane: the system's browser is opened instead
    sys <- function(url) opened <<- paste("system:", url)
    expect_identical(.open_viewer("u", ide = "positron", pane = pane, system = sys, local = TRUE), "system")
    expect_identical(opened, "system: u")
    expect_identical(.open_viewer("u", ide = "none", pane = pane, system = sys, local = TRUE), "browser")
    expect_identical(opened, "browser: u")
    # R on another machine: the system's browser there is not the user's
    expect_identical(.open_viewer("u", ide = "positron", pane = pane, system = sys, local = FALSE), "browser")
    expect_identical(opened, "browser: u")
})

test_that("an open that runs a command gets the launch page, another the URL", {
    opened <- NULL
    pane <- function(url) opened <<- url
    sys <- function(url) opened <<- url
    launch <- function(command) if (command) "page" else "url"
    old <- options(browser = function(url) opened <<- url, GiottoLens.viewer = NULL)
    on.exit(options(old), add = TRUE)

    .open_viewer("u", ide = "rstudio", pane = pane, launch = launch)
    expect_identical(opened, "url")
    .open_viewer("u", ide = "positron", pane = pane, launch = launch)
    expect_identical(opened, "url")
    .open_viewer("u", ide = "none", pane = pane, launch = launch)
    expect_identical(opened, "url")
    options(GiottoLens.viewer = "browser")
    .open_viewer("u", ide = "positron", pane = pane, system = sys, local = TRUE, launch = launch)
    expect_identical(opened, "page")

    # `options(browser =)` a command: browseURL() runs it with what it opens
    skip_on_os("windows")
    out <- withr::local_tempfile()
    script <- withr::local_tempfile(fileext = ".sh")
    writeLines(c("#!/bin/sh", paste0("printf %s \"$1\" > ", shQuote(out))), script)
    Sys.chmod(script, "0700")
    options(browser = script, GiottoLens.viewer = NULL)
    .open_viewer("u", ide = "none", pane = pane, launch = launch)
    expect_true(pump_until(function() file.exists(out) && length(readLines(out, warn = FALSE))))
    expect_identical(readLines(out, warn = FALSE), "page")
})

test_that(".local_session() is FALSE over SSH, in Positron Server and without a display", {
    env <- function(...) {
        set <- c(character(), ...)
        function(x) {
            out <- set[x]
            out[is.na(out)] <- ""
            unname(out)
        }
    }
    yes <- function(cmd) TRUE
    expect_true(.local_session(env(), "Darwin"))
    expect_true(.local_session(env(), "Windows"))
    expect_false(.local_session(env(SSH_CONNECTION = "10.0.0.1 50000 10.0.0.2 22"), "Darwin"))
    expect_false(.local_session(env(SSH_TTY = "/dev/pts/0"), "Linux", yes))
    expect_false(.local_session(env(POSITRON_MODE = "server"), "Darwin"))
    expect_false(.local_session(env(), "Linux", yes))
    expect_true(.local_session(env(DISPLAY = ":0"), "Linux", yes))
    expect_true(.local_session(env(WAYLAND_DISPLAY = "wayland-0"), "Linux", yes))
    expect_false(.local_session(env(DISPLAY = ":0"), "Linux", function(cmd) FALSE))
})

test_that(".ide reads the IDE from the environment", {
    old <- Sys.getenv(c("POSITRON", "RSTUDIO", "RSTUDIO_PROGRAM_MODE"), unset = NA)
    on.exit(for (k in names(old))
        if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(old[k])), add = TRUE)
    Sys.unsetenv(c("POSITRON", "RSTUDIO", "RSTUDIO_PROGRAM_MODE"))
    expect_identical(.ide(), "none")
    Sys.setenv(RSTUDIO = "1", RSTUDIO_PROGRAM_MODE = "desktop")
    expect_identical(.ide(), "rstudio")
    Sys.setenv(RSTUDIO_PROGRAM_MODE = "server")
    expect_identical(.ide(), "rstudio-server")
    Sys.setenv(POSITRON = "1")
    expect_identical(.ide(), "positron")
})

# ── The launch page ──────────────────────────────────────────────────────────

test_that("opened by a command, launch_lens() opens a page whose key lets one window in", {
    skip_if_not_installed("websocket")
    fx <- lens_fixture()
    opened <- NULL
    local_mocked_bindings(.open_viewer = function(url, ..., launch) opened <<- launch(TRUE))
    v <- suppressMessages(launch_lens(fx$gpoints, fx$gpolygons, open = TRUE))
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)
    file <- priv$launch_file
    expect_identical(opened, .file_url(file))
    expect_false(grepl(priv$token, opened, fixed = TRUE))
    expect_false(startsWith(normalizePath(file), paste0(normalizePath(priv$session), "/")))
    page <- paste(readLines(file), collapse = "\n")
    key <- priv$launch_key
    expect_match(key, "^[A-Za-z0-9]{24}$")
    expect_true(grepl(paste0(v$url, "#launch=", key), page, fixed = TRUE))
    if (.Platform$OS.type == "unix") expect_identical(format(file.mode(file)), "600")
    hello <- function(launch) jsonlite::toJSON(list(type = "hello",
        data = list(protocol = .lens_protocol, key = NULL, launch = launch)), auto_unbox = TRUE, null = "null")

    # The viewer URL alone, or another key: a code
    a <- b <- NULL
    suppressMessages({
        a <- window_raw(v)
        b <- window_raw(v, first = hello("wrong"))
        expect_true(pump_until(function() length(ws_msgs(a, "wait")) && length(ws_msgs(b, "wait"))))
    })
    expect_false(v$connected())
    expect_false(priv$allow_next)

    d <- window_raw(v, first = hello(key))
    expect_true(pump_until(function() length(ws_msgs(d, "grant")) > 0L))
    expect_null(priv$launch_key)
    expect_false(file.exists(file))

    # The key works once
    e <- NULL
    suppressMessages({
        e <- window_raw(v, first = hello(key))
        expect_true(pump_until(function() length(ws_msgs(e, "wait")) > 0L))
    })
    expect_length(ws_msgs(e, "grant"), 0L)
    for (cl in list(a, b, d, e)) cl$ws$close()
})

test_that("close() removes the page launch_lens() opened", {
    fx <- lens_fixture()
    local_mocked_bindings(.open_viewer = function(url, ..., launch) launch(TRUE))
    v <- suppressMessages(launch_lens(fx$gpoints, fx$gpolygons, open = TRUE))
    file <- lens_priv(v)$launch_file
    expect_true(file.exists(file))
    suppressMessages(v$close())
    expect_false(file.exists(file))
})

test_that("the page launch_lens() opens escapes the URL", {
    file <- .write_launch_page("http://h/a\"b<c&d#launch=k", dir = withr::local_tempdir())
    page <- readLines(file)
    expect_true(any(grepl("url=http://h/a&quot;b&lt;c&amp;d#launch=k\"", page, fixed = TRUE)))
    expect_true(any(grepl("location.replace(\"http://h/a\\\"b\\u003cc&d#launch=k\")", page, fixed = TRUE)))
})
