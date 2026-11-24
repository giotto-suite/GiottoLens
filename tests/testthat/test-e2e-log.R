# Browser: what the page asked R to do reports on the status line, and the
# log slides up from the bottom bar

test_that("an action's notice shows on the status line and the log opens from the bar", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "!!window.__giottolens?.state.cells"))
    expect_true(pump_until(function() v$connected()))
    priv <- lens_priv(v)
    notice <- "document.getElementById('notice')"
    badge <- "document.querySelector('#btn-log .log-badge')"
    expect_true(br$js(sprintf("%s.hidden", notice)))

    # One action, three conditions: one notice, at its worst level
    priv$for_page("set_column_type", {
        warning("[LensViewer] <b>first</b>")
        message("second")
        stop("[LensViewer] third", call. = FALSE)
    })
    expect_true(browser_wait(br, sprintf("!%s.hidden", notice)))
    expect_true(br$js(sprintf("%s.classList.contains('lvl-error')", notice)))
    expect_identical(br$js(sprintf("%s.querySelector('.notice-text').textContent", notice)),
        "set column type: third")
    expect_identical(br$js(sprintf("%s.querySelector('.notice-more').textContent", notice)), "+2 more")
    expect_identical(br$js(sprintf("%s.textContent", badge)), "1")
    expect_true(br$js(sprintf("%s.classList.contains('error')", badge)))
    # The status line gives way while it shows
    expect_identical(br$js("getComputedStyle(document.getElementById('status')).display"), "none")

    # Clicking it opens the log, read: newest first, the items expand, text stays text
    br$js(sprintf("%s.click()", notice))
    expect_true(browser_wait(br, "document.getElementById('log-drawer').classList.contains('open')"))
    expect_true(br$js(sprintf("%s.hidden", notice)))
    expect_identical(br$js(sprintf("%s.textContent", badge)), "")
    row <- "document.querySelector('#log-drawer .log-row')"
    expect_true(br$js(sprintf("%s.classList.contains('lvl-error')", row)))
    br$js(sprintf("%s.querySelector('.log-toggle').click()", row))
    expect_true(browser_wait(br, "document.querySelectorAll('#log-drawer .log-item').length === 3"))
    expect_identical(br$js("document.querySelector('#log-drawer .log-item').textContent"), "<b>first</b>")
    expect_identical(br$js("document.querySelectorAll('#log-drawer b').length"), 0L)

    # A message alone goes by itself; Escape closes the log
    br$js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
    expect_false(br$js("document.getElementById('log-drawer').classList.contains('open')"))
    priv$for_page("pull", message("pulled 1 column(s): a"))
    expect_true(browser_wait(br, sprintf("%s.classList.contains('lvl-message')", notice)))
    expect_identical(br$js(sprintf("%s.textContent", badge)), "")
    expect_true(browser_wait(br, sprintf("%s.hidden", notice), timeout = 10))

    # The page keeps the same log as R
    expect_identical(br$js("window.__giottolens.log.length"), length(priv$log_entries))
    expect_no_browser_errors(br)
})
