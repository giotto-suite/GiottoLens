# One window shows the viewer (adr/0028)

# ── Helpers ──────────────────────────────────────────────────────────────────

window_viewer <- function() {
    fx <- lens_fixture()
    v <- suppressMessages(launch_lens(fx$gpoints, fx$gpolygons, open = FALSE))
    list(v = v, priv = lens_priv(v))
}
window_tile <- function(priv) jsonlite::fromJSON(file.path(priv$session, "manifest.json"),
    simplifyVector = FALSE)$layers$transcripts$tiles[[1L]]

# ── Waiting and allow(code) ──────────────────────────────────────────────────

test_that("a window R did not let in waits with a code; allow(code) gives it the viewer", {
    skip_if_not_installed("websocket")
    skip_if_not_installed("curl")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    first <- priv$routes$secret
    tile <- window_tile(priv)
    a <- NULL
    said <- testthat::capture_messages({
        a <- ws_client(ws_url(v), allow = FALSE)
        pump_until(function() !is.null(a$state$wait))
    })
    expect_match(said, "a window asks to show the viewer; viewer\\$allow\\(<the code it shows>\\)")
    code <- a$state$wait$code
    expect_match(code, "^[1-9][0-9]{3}$")
    expect_false(v$connected())
    # R names the code nowhere: it is read in the window
    shown <- utils::capture.output(print(v$describe()), print(v))
    expect_true(any(grepl("waiting +1 window\\(s\\)", shown)))
    expect_false(any(grepl(code, c(said, shown), fixed = TRUE)))
    # Without the code, or with another, R says what to do and changes nothing
    expect_warning(v$allow(), "a window is waiting for the viewer. Read the code that window shows, then run viewer\\$allow\\(<code>\\)")
    wrong <- if (code == "1000") "1001" else "1000"
    expect_warning(v$allow(wrong), paste0("no waiting window shows code ", wrong, ". Read the code"))
    pump_for(0.2)
    expect_false(v$connected())
    expect_null(a$state$grant)
    expect_false(priv$allow_next)

    # Not listened to
    ws_say(a, "ready", list(protocol = .lens_protocol))
    ws_say(a, "close")
    pump_for(0.3)
    expect_false(v$connected())
    expect_false(is.null(priv$server))
    expect_null(a$state$grant)

    expect_message(v$allow(code), NA)
    expect_true(pump_until(function() v$connected()))
    expect_match(a$state$grant$key, "^[A-Za-z0-9]{24}$")
    expect_identical(a$state$grant$data, priv$routes$secret)
    expect_false(identical(a$state$grant$data, first))
    expect_true(pump_until(function() length(ws_msgs(a, "restore")) > 0L))
    # The data under the new secret; that the old one ends is checked on a move
    for (u in c(tile$url, tile$file, "session/manifest.json"))
        expect_identical(http_get(lens_data_url(v, u))$status_code, 200L, info = u)
    a$ws$close()
})

test_that("the window that shows the viewer moves it to one that waits by its code", {
    skip_if_not_installed("websocket")
    skip_if_not_installed("curl")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    tile <- window_tile(priv)
    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() v$connected()))
    b <- NULL
    suppressMessages({
        b <- ws_client(ws_url(v), allow = FALSE, key = "not-the-key")
        expect_true(pump_until(function() length(ws_msgs(a, "claim_request")) > 0L))
    })
    code <- b$state$wait$code
    # The window that shows the viewer hears that a window waits, not its code
    expect_identical(ws_msgs(a, "claim_request")[[1L]]$data, list(waiting = 1L))
    expect_false(grepl(code, jsonlite::toJSON(a$state$msgs, auto_unbox = TRUE), fixed = TRUE))
    answer <- function(cl, id) Find(function(m) m$type == "answer" && identical(m$data$id, id),
        cl$state$msgs)$data

    # Only the window that shows the viewer can give the code
    ws_ask(b, "b1", op = "claim", code = code)
    pump_for(0.3)
    expect_null(b$state$grant)
    expect_null(answer(b, "b1"))
    # A code no waiting window shows moves nothing
    ws_ask(a, "a1", op = "claim", code = if (code == "1000") "1001" else "1000")
    expect_true(pump_until(function() !is.null(answer(a, "a1"))))
    expect_identical(answer(a, "a1")$error, "no waiting window shows that code")
    expect_null(b$state$grant)
    expect_true(v$connected())

    before <- lens_data_url(v, tile$url)
    said <- testthat::capture_messages({
        ws_ask(a, "a2", op = "claim", code = code)
        pump_until(function() !is.null(b$state$grant))
    })
    expect_match(said, "the viewer moved to another window")
    expect_false(grepl(code, paste(said, collapse = " "), fixed = TRUE))
    expect_null(answer(a, "a2")$error)
    expect_true(pump_until(function() isTRUE(a$state$released)))
    expect_false(identical(b$state$grant$key, a$state$grant$key))
    expect_false(identical(b$state$grant$data, a$state$grant$data))
    expect_identical(http_get(before)$status_code, 404L)
    expect_identical(http_get(lens_data_url(v, tile$url))$status_code, 200L)

    # R talks to the new window only, and no longer listens to the old one
    expect_true(pump_until(function() length(ws_msgs(b, "restore")) > 0L))
    n <- length(a$state$msgs)
    v$send("ping")
    expect_true(pump_until(function() length(ws_msgs(b, "ping")) > 0L))
    ws_say(a, "close")
    pump_for(0.3)
    expect_length(a$state$msgs, n)
    expect_false(is.null(priv$server))
    a$ws$close(); b$ws$close()
})

test_that("allow() lets the next window in once, and warns without the code of a waiting window", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v
    on.exit(v$close(), add = TRUE)
    expect_warning(v$allow("1234"), "no waiting window shows code 1234. No window is waiting")
    expect_message(v$allow(), "the next window to open the viewer URL shows the viewer")
    a <- ws_client(ws_url(v), allow = FALSE)
    expect_true(pump_until(function() v$connected()))
    b <- d <- NULL
    suppressMessages({
        b <- ws_client(ws_url(v), allow = FALSE)
        d <- ws_client(ws_url(v), allow = FALSE)
        expect_true(pump_until(function() !is.null(b$state$wait) && !is.null(d$state$wait)))
    })
    expect_null(b$state$grant)
    expect_warning(v$allow(), "a window is waiting for the viewer")
    expect_warning(v$allow("0"), "no waiting window shows code 0")
    expect_error(v$allow(c(1, 2)), "`code` must be one code")
    v$allow(as.integer(d$state$wait$code))
    expect_true(pump_until(function() !is.null(d$state$grant) && isTRUE(a$state$released)))
    expect_null(b$state$grant)
    for (cl in list(a, b, d)) cl$ws$close()
})

test_that("launch_lens(open = TRUE) gives the window it opens the viewer", {
    skip_if_not_installed("websocket")
    fx <- lens_fixture()
    opened <- NULL
    local_mocked_bindings(.open_viewer = function(url, ..., launch) opened <<- launch(FALSE))
    v <- suppressMessages(launch_lens(fx$gpoints, fx$gpolygons, open = TRUE))
    on.exit(v$close(), add = TRUE)
    expect_identical(opened, v$url)
    a <- ws_client(ws_url(v), allow = FALSE)
    expect_true(pump_until(function() v$connected()))
    b <- NULL
    suppressMessages({
        b <- ws_client(ws_url(v), allow = FALSE)
        expect_true(pump_until(function() !is.null(b$state$wait)))
    })
    # close() tells the waiting window too
    v$close()
    expect_true(pump_until(function() length(ws_msgs(a, "closed")) && length(ws_msgs(b, "closed"))))
})

# ── Reload and key ───────────────────────────────────────────────────────────

test_that("a reload keeps the viewer with its key; an old key does not", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() v$connected()))
    old <- a$state$grant
    b <- ws_client(ws_url(v))                      # allow(): the viewer moves to b
    expect_true(pump_until(function() !is.null(b$state$grant) && isTRUE(a$state$released)))
    grant <- b$state$grant
    b$ws$close()
    expect_true(pump_until(function() !v$connected()))

    b2 <- ws_client(ws_url(v), allow = FALSE, key = grant$key)
    expect_true(pump_until(function() v$connected()))
    expect_identical(b2$state$grant, grant)

    stale <- NULL
    suppressMessages({
        stale <- ws_client(ws_url(v), allow = FALSE, key = old$key)
        expect_true(pump_until(function() !is.null(stale$state$wait)))
    })
    expect_null(stale$state$grant)
    # A waiting window that closes withdraws its request
    expect_true(pump_until(function() length(ws_msgs(b2, "claim_request")) > 0L))
    stale$ws$close()
    expect_true(pump_until(function() length(ws_msgs(b2, "claim_request")) > 1L))
    expect_identical(lapply(ws_msgs(b2, "claim_request"), function(m) m$data$waiting), list(1L, 0L))
    expect_length(priv$waiting, 0L)
    a$ws$close(); b2$ws$close()
})

test_that("the key from a second connection: a code while the window that shows the viewer answers", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() v$connected()))
    grant <- a$state$grant
    d <- NULL
    suppressMessages({
        d <- window_raw(v, key = grant$key)
        expect_true(pump_until(function() length(ws_msgs(a, "probe")) > 0L))
        expect_length(d$state$msgs, 0L)
        a$ws$send(jsonlite::toJSON(list(type = "reply", id = ws_msgs(a, "probe")[[1L]]$id,
            data = list()), auto_unbox = TRUE))
        expect_true(pump_until(function() length(ws_msgs(d, "wait")) > 0L))
    })
    expect_length(ws_msgs(d, "grant"), 0L)
    expect_true(v$connected())
    expect_null(a$state$released)
    d$ws$close()
    expect_true(pump_until(function() length(priv$waiting) == 0L))

    # No answer: it is the same window again
    e <- window_raw(v, key = grant$key)
    expect_true(pump_until(function() length(ws_msgs(a, "probe")) > 1L))
    expect_true(pump_until(function() length(ws_msgs(e, "grant")) > 0L,
        timeout = .lens_probe_wait + 5))
    expect_identical(ws_msgs(e, "grant")[[1L]]$data, grant)
    expect_true(pump_until(function() isTRUE(a$state$released)))
    a$ws$close(); e$ws$close()
})

test_that("the window the viewer moved from gets it back while the new one is not ready", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() v$connected()))
    old <- a$state$grant
    b <- a2 <- NULL
    suppressMessages({
        b <- window_raw(v)
        expect_true(pump_until(function() length(ws_msgs(b, "wait")) > 0L))
    })
    v$allow(ws_msgs(b, "wait")[[1L]]$data$code)
    expect_true(pump_until(function() length(ws_msgs(b, "grant")) > 0L && isTRUE(a$state$released)))
    expect_false(v$connected())
    # While the new window is there, the old key gets a code
    suppressMessages({
        a2 <- window_raw(v, key = old$key)
        expect_true(pump_until(function() length(ws_msgs(a2, "wait")) > 0L))
    })
    expect_length(ws_msgs(a2, "grant"), 0L)
    a2$ws$close(); b$ws$close()
    expect_true(pump_until(function() is.null(priv$pending) && length(priv$waiting) == 0L))

    a3 <- ws_client(ws_url(v), allow = FALSE, key = old$key)
    expect_true(pump_until(function() v$connected()))
    expect_false(identical(a3$state$grant$key, old$key))
    expect_false(identical(a3$state$grant$data, old$data))
    # Not once a window said `ready`
    a3$ws$close()
    expect_true(pump_until(function() !v$connected()))
    a4 <- NULL
    suppressMessages({
        a4 <- window_raw(v, key = old$key)
        expect_true(pump_until(function() length(ws_msgs(a4, "wait")) > 0L))
    })
    expect_length(ws_msgs(a4, "grant"), 0L)
    a$ws$close(); a4$ws$close()
})

# ── Window limits ────────────────────────────────────────────────────────────

test_that("past the limit of other windows the oldest idle one is closed", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() v$connected()))
    key <- a$state$grant$key
    b <- NULL
    suppressMessages({
        b <- window_raw(v)
        expect_true(pump_until(function() length(ws_msgs(b, "wait")) > 0L))
    })
    idle <- lapply(seq_len(.lens_knocks_max - 1L), function(i) window_raw(v, first = character()))
    expect_true(pump_until(function() length(priv$knocks) == .lens_knocks_max))
    a$ws$close()
    expect_true(pump_until(function() !v$connected()))

    # The window that shows the viewer reloads
    a2 <- ws_client(ws_url(v), allow = FALSE, key = key)
    expect_true(pump_until(function() v$connected()))
    closed <- function() sum(vapply(idle, function(cl) cl$state$closed, TRUE))
    expect_true(pump_until(function() closed() == 1L))
    expect_false(b$state$closed)
    expect_length(priv$waiting, 1L)
    for (cl in c(list(a2, b), idle)) cl$ws$close()
})

test_that("past the limit of waiting windows the oldest one is closed", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    wins <- list()
    suppressMessages({
        for (i in seq_len(.lens_waiting_max)) {
            wins[[i]] <- window_raw(v)
            expect_true(pump_until(function() length(priv$waiting) == i))
        }
        last <- window_raw(v)
        expect_true(pump_until(function() length(ws_msgs(last, "wait")) > 0L && wins[[1L]]$state$closed))
    })
    expect_length(priv$waiting, .lens_waiting_max)
    expect_false(any(vapply(wins[-1L], function(cl) cl$state$closed, TRUE)))
    expect_false(last$state$closed)
    expect_false(ws_msgs(wins[[1L]], "wait")[[1L]]$data$code %in% unlist(priv$waiting))
    for (cl in c(wins, list(last))) cl$ws$close()
})

# ── Stale pages ──────────────────────────────────────────────────────────────

test_that("the protocol of a page from before `hello` is named only when it is one number", {
    skip_if_not_installed("websocket")
    for (proto in c('"7\\nrun this"', "[7,9]", "null", '{"a":7}')) {
        w <- window_viewer(); v <- w$v; priv <- w$priv
        said <- testthat::capture_warnings({
            window_raw(v, first = sprintf('{"type":"ready","data":{"protocol":%s}}', proto))
            pump_until(function() priv$stale_warned)
        })
        v$close()
        expect_identical(said, paste0("[LensViewer] the viewer bundle speaks protocol ?, this package ",
            .lens_protocol, "; reinstall GiottoLens or rebuild inst/viewer"))
    }
})

test_that("a page from before `hello` is warned of once; other windows do not warn", {
    skip_if_not_installed("websocket")
    w <- window_viewer(); v <- w$v; priv <- w$priv
    on.exit(v$close(), add = TRUE)
    ready <- '{"type":"ready","data":{"protocol":7}}'
    old <- NULL
    expect_warning({
        old <- window_raw(v, first = c(ready, ready))
        pump_until(function() priv$stale_warned)
        pump_for(0.3)
    }, paste0("the viewer bundle speaks protocol 7, this package ", .lens_protocol,
        "; reinstall GiottoLens or rebuild inst/viewer"))
    expect_length(old$state$msgs, 0L)

    x <- NULL
    expect_no_warning(suppressMessages({
        x <- window_raw(v, first = c('{"type":"hello","data":"s"}', "not json", '{"type":"nope"}',
            sprintf('{"type":"ready","data":{"protocol":%d}}', .lens_protocol)))
        expect_true(pump_until(function() length(ws_msgs(x, "wait")) > 0L))
        pump_for(0.3)
    }))
    expect_false(v$connected())
    old$ws$close(); x$ws$close()
})

# ── close() ──────────────────────────────────────────────────────────────────

test_that("close() with no window connected sends nothing", {
    w <- window_viewer(); v <- w$v
    sent <- character()
    encode <- .encode_ws_message
    local_mocked_bindings(.encode_ws_message = function(type, ...) {
        sent <<- c(sent, type)
        encode(type, ...)
    })
    suppressMessages(v$close())
    expect_false("closed" %in% sent)
})
