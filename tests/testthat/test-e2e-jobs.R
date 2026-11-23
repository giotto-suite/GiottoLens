# Browser: the jobs button lists, cancels and keeps jobs

test_that("the jobs button lists running jobs, cancels one, and keeps the finished", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    priv <- lens_priv(v)
    btn <- "document.querySelector('[data-panel=tools] [data-act=jobs]')"
    badge <- sprintf("%s.querySelector('.jobs-badge').textContent", btn)
    expect_identical(br$js(badge), "")

    end <- NULL
    id <- priv$start_job("long wait", function(g) { Sys.sleep(60); 1 }, on_end = function(r) end <<- r)
    expect_true(browser_wait(br, sprintf("%s === '1'", badge)))
    expect_true(br$js(sprintf("%s.classList.contains('busy')", btn)))
    br$js(sprintf("%s.click()", btn))
    expect_true(browser_wait(br, "!!document.querySelector('.jobs-popover .job-row.state-running')"))
    expect_identical(br$js("document.querySelector('.jobs-popover .job-label').textContent"), "long wait")

    later::run_now(0.5)
    br$js("document.querySelector('.jobs-popover .job-cancel').click()")
    expect_true(pump_until(function() identical(end$state, "cancelled"), timeout = 15))
    expect_true(browser_wait(br, "!!document.querySelector('.jobs-popover .job-row.state-cancelled')"))
    expect_identical(br$js(badge), "")
    expect_false(br$js(sprintf("%s.classList.contains('busy')", btn)))
    expect_length(v$jobs()$id, 0L)
    expect_no_browser_errors(br)
})
