# What the page asks R to do reports to the page, as one log entry per action,
# never to the console; R's own calls keep the console.

test_that("an action's conditions become one log entry at its worst level", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)

    expect_no_warning(expect_no_message(expect_null(priv$for_page("act", {
        warning("[site] first")
        message("[site] second")
        stop("[site] third", call. = FALSE)
        "not reached"
    }))))
    e <- utils::tail(priv$log_entries, 1L)[[1L]]
    expect_identical(e$action, "error")
    expect_identical(e$detail$where, "act")
    expect_identical(e$detail$message, "third")
    expect_identical(vapply(e$detail$items, `[[`, "", "level"), c("warning", "message", "error"))
    expect_identical(vapply(e$detail$items, `[[`, "", "text"), c("first", "second", "third"))

    # A warning alone; the value comes back
    expect_identical(priv$for_page("act", { warning("w"); 1 }), 1)
    expect_identical(utils::tail(priv$log_entries, 1L)[[1L]]$action, "warning")

    # Nothing raised: nothing logged
    n <- length(priv$log_entries)
    priv$for_page("act", 1)
    expect_length(priv$log_entries, n)

    # Past the cap, a count
    priv$for_page("many", for (i in seq_len(.lens_notice_items + 3L)) message(i))
    e <- utils::tail(priv$log_entries, 1L)[[1L]]$detail
    expect_length(e$items, .lens_notice_items)
    expect_identical(e$more, 3L)

    # What the page did, told to the R console: stays there
    n <- length(priv$log_entries)
    expect_message(priv$for_page("claim", .console_message("[LensViewer] moved")), "moved")
    expect_length(priv$log_entries, n)

    # R's own calls: the console, as before
    expect_warning(priv$for_page(NULL, warning("for R")), "for R")
    expect_warning(priv$report("warning", "for R"), "for R")
})

test_that("an error from the page's message reaches the page, not the console", {
    skip_if_not_installed("websocket")
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    cl <- ws_client(ws_url(v))
    on.exit(cl$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() length(ws_msgs(cl, "log_entries")) > 0L, 10))

    expect_no_warning({
        cl$ws$send('{"type":"set_column_type","data":{"column":"nope","type":"categorical"}}')
        expect_true(pump_until(function() length(ws_msgs(cl, "log_entry")) > 0L, 10))
    })
    e <- utils::tail(ws_msgs(cl, "log_entry"), 1L)[[1L]]$data
    expect_identical(e$action, "error")
    expect_identical(e$detail$where, "set_column_type")
    expect_match(e$detail$message, "no metadata")
    expect_identical(utils::tail(v$log(1L)$action, 1L), "error")

    # A reload gets the log so far
    cl2 <- ws_client(ws_url(v))
    on.exit(cl2$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() length(ws_msgs(cl2, "log_entries")) > 0L, 10))
    entries <- ws_msgs(cl2, "log_entries")[[1L]]$data$entries
    expect_true(any(vapply(entries, function(x) is.list(x$detail) && identical(x$detail$where, "set_column_type"), NA)))
})
