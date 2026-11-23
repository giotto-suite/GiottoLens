test_that("the Analysis panel opens in the left tray and drives the steps from the page", {
    fx <- lens_analysis_fixture()
    v <- suppressMessages(launch_lens(fx$g, feat_type = NULL, open = FALSE))
    on.exit(suppressMessages(v$close()), add = TRUE)
    br <- lens_browser(v$url, width = 1600, height = 900)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected(), 30))
    priv <- lens_priv(v)
    # Opened in the left tray from the tools rail, not offered by the dock's
    # "+"; opening it makes the analysis, which runs nothing
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    br$js("[...document.querySelectorAll('.dock-add')].find(b => b.offsetParent).click()")
    expect_false(br$js("[...document.querySelectorAll('.dock-menu.open button')].some(b => b.textContent === 'analysis')"))
    br$js("document.body.click()")
    br$js("document.querySelector('[data-panel=tools] [data-act=analysis]').click()")
    expect_true(pump_until(function() !is.null(priv$lens_analysis), 30))
    expect_true(browser_wait(br, "!!document.querySelector('#drawer.open [data-panel=analysis] .an-step')", 30))
    p <- v$panels()
    expect_identical(p$group[p$id == "analysis"], "drawer")
    a <- v$analysis(params = lens_analysis_params)
    later::run_now(0.5)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "stale"))

    # A number typed on the page reaches R and runs the steps
    br$js("(() => { const s = document.querySelector('[data-step=leiden] input[data-param=resolution]');
        s.value = '0.37'; s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function() identical(a$params()$leiden$resolution, 0.37), 10))
    a$wait(300)
    expect_true(browser_wait(br,
        "document.querySelectorAll('[data-panel=analysis] .an-step.an-done').length === 10", 30))
    expect_true(browser_wait(br, "window.__giottolens.store.getState().colorBy === 'leiden_clus'", 30))
    # Its steps showed as jobs
    expect_true(browser_wait(br, "[...document.querySelectorAll('.jobs-badge')].length > 0"))

    # A change from R shows in the page's menu
    a$set("umap", min_dist = 0.3)
    expect_true(browser_wait(br,
        "document.querySelector('[data-step=umap] input[data-param=min_dist]').value === '0.3'", 30))
    a$wait(120)

    # Closed from R, the left tray goes; its width drags from its right edge
    # and stays after a reload, open again
    v$remove_panel("analysis")
    expect_true(browser_wait(br, "!document.querySelector('#drawer.open')"))
    expect_false("analysis" %in% v$panels()$id)
    br$js("document.querySelector('[data-panel=tools] [data-act=analysis]').click()")
    expect_true(browser_wait(br, "!!document.querySelector('#drawer.open')"))
    expect_equal(br$js("document.getElementById('drawer').getBoundingClientRect().width"), 360, tolerance = 2)
    e <- br$js("(() => { const r = document.querySelector('#drawer .drawer-sash').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()")
    send <- function(type, x) br$session$Input$dispatchMouseEvent(type = type, x = x, y = e[[2]], button = "left",
        buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mousePressed", e[[1]]); send("mouseMoved", e[[1]] + 40); send("mouseMoved", e[[1]] + 100); send("mouseReleased", e[[1]] + 100)
    expect_true(pump_until(function() grepl('"drawerWidth":4', priv$config_json %||% "", fixed = TRUE), 10))
    br$js("location.reload()")
    Sys.sleep(0.3)
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected') && !!document.querySelector('#drawer.open [data-panel=analysis]')", 30))
    expect_equal(br$js("document.getElementById('drawer').getBoundingClientRect().width"), 460, tolerance = 3)
    expect_length(br$errors(), 0L)
})
