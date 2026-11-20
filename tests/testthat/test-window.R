# One window shows the viewer (adr/0028)

window_viewer <- function() {
    fx <- lens_fixture()
    v <- suppressMessages(launch_lens(fx$gpoints, fx$gpolygons, open = FALSE))
    list(v = v, priv = get("private", v$.__enclos_env__))
}
window_got <- function(cl, type) Filter(function(m) m$type == type, cl$state$msgs)
window_say <- function(cl, type, data = NULL)
    cl$ws$send(jsonlite::toJSON(list(type = type, data = data), auto_unbox = TRUE, null = "null"))
window_tile <- function(priv) jsonlite::fromJSON(file.path(priv$session, "manifest.json"),
    simplifyVector = FALSE)$layers$transcripts$tiles[[1L]]

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
    pump_until(function() FALSE, timeout = 0.2)
    expect_false(v$connected())
    expect_null(a$state$grant)
    expect_false(priv$allow_next)

    # Not listened to, and no data without the secret
    window_say(a, "ready", list(protocol = .lens_protocol))
    window_say(a, "close")
    pump_until(function() FALSE, timeout = 0.3)
    expect_false(v$connected())
    expect_false(is.null(priv$server))
    expect_null(a$state$grant)
    expect_identical(http_get(paste0(v$url, tile$url))$status_code, 404L)

    expect_message(v$allow(code), NA)
    expect_true(pump_until(function() v$connected()))
    expect_match(a$state$grant$key, "^[A-Za-z0-9]{24}$")
    expect_identical(a$state$grant$data, priv$routes$secret)
    expect_false(identical(a$state$grant$data, first))
    expect_true(pump_until(function() length(window_got(a, "restore")) > 0L))
    for (u in c(tile$url, tile$file, "session/manifest.json")) {
        expect_identical(http_get(lens_data_url(v, u))$status_code, 200L, info = u)
        expect_identical(http_get(paste0(v$url, "d/", first, "/", u))$status_code, 404L, info = u)
    }
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
        expect_true(pump_until(function() length(window_got(a, "claim_request")) > 0L))
    })
    code <- b$state$wait$code
    # The window that shows the viewer hears that a window waits, not its code
    expect_identical(window_got(a, "claim_request")[[1L]]$data, list(waiting = 1L))
    expect_false(grepl(code, jsonlite::toJSON(a$state$msgs, auto_unbox = TRUE), fixed = TRUE))
    claim <- function(cl, id, code) cl$ws$send(jsonlite::toJSON(list(type = "ask", id = id,
        data = list(op = "claim", code = code)), auto_unbox = TRUE))
    answer <- function(cl, id) Find(function(m) m$type == "answer" && identical(m$data$id, id),
        cl$state$msgs)$data

    # Only the window that shows the viewer can give the code
    claim(b, "b1", code)
    pump_until(function() FALSE, timeout = 0.3)
    expect_null(b$state$grant)
    expect_null(answer(b, "b1"))
    # A code no waiting window shows moves nothing
    claim(a, "a1", if (code == "1000") "1001" else "1000")
    expect_true(pump_until(function() !is.null(answer(a, "a1"))))
    expect_identical(answer(a, "a1")$error, "no waiting window shows that code")
    expect_null(b$state$grant)
    expect_true(v$connected())

    before <- lens_data_url(v, tile$url)
    said <- testthat::capture_messages({
        claim(a, "a2", code)
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
    expect_true(pump_until(function() length(window_got(b, "restore")) > 0L))
    n <- length(a$state$msgs)
    v$send("ping")
    expect_true(pump_until(function() length(window_got(b, "ping")) > 0L))
    window_say(a, "close")
    pump_until(function() FALSE, timeout = 0.3)
    expect_length(a$state$msgs, n)
    expect_false(is.null(priv$server))
    a$ws$close(); b$ws$close()
})

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
    expect_true(pump_until(function() length(window_got(b2, "claim_request")) > 0L))
    stale$ws$close()
    expect_true(pump_until(function() length(window_got(b2, "claim_request")) > 1L))
    expect_identical(lapply(window_got(b2, "claim_request"), function(m) m$data$waiting), list(1L, 0L))
    expect_length(priv$waiting, 0L)
    a$ws$close(); b2$ws$close()
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
    local_mocked_bindings(.open_viewer = function(url, ...) opened <<- url)
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
    expect_true(pump_until(function() length(window_got(a, "closed")) && length(window_got(b, "closed"))))
})

test_that("the code of a waiting window is four digits", {
    codes <- replicate(200L, .rand_code())
    expect_true(all(grepl("^[1-9][0-9]{3}$", codes)))
    expect_gt(length(unique(codes)), 150L)
})
