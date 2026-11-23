# Browser: pan and zoom input (Space, middle button, releases outside the page, set_view after a hand zoom)

test_that("holding Space pans with any tool, and the tool comes back on release", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    key <- function(type) br$session$Input$dispatchKeyEvent(type = type, code = "Space", key = " ",
        windowsVirtualKeyCode = 32L)
    pan_lit <- function() br$js("document.querySelector('.tool-btn[data-mode=\"pan\"]').classList.contains('active')")
    mode <- function() br$js("window.__giottolens.store.getState().mode")
    size <- br$js("(() => { const c = window.__giottolens.spatial.canvas; return [c.clientWidth, c.clientHeight]; })()")
    cx <- size[[1]] / 2; cy <- size[[2]] / 2
    target <- function() unlist(br$js("window.__giottolens.spatial.viewState.target"))[1:2]

    set_tool(br, "lasso")
    expect_false(pan_lit())
    key("keyDown")
    expect_true(browser_wait(br, "document.querySelector('.tool-btn[data-mode=\"pan\"]').classList.contains('active')"))
    expect_identical(mode(), "lasso")   # the tool is kept, not replaced by pan
    # A drag while held pans and selects nothing
    t0 <- target()
    browser_drag(br, list(c(cx, cy), c(cx + 40, cy), c(cx + 80, cy + 20)))
    expect_true(pump_until(function() sum(abs(target() - t0)) > 0))
    expect_length(v$selection, 0L)
    key("keyUp")
    expect_false(pan_lit())
    expect_identical(mode(), "lasso")
    # With the pan tool, a held drag pans once: deck.gl does not pan as well
    br$js("window.__giottolens.actions.setMode('pan')")
    scale <- br$js("2 ** window.__giottolens.spatial.viewState.zoom")
    key("keyDown")
    t0 <- target()
    browser_drag(br, list(c(cx, cy), c(cx + 40, cy), c(cx + 80, cy + 20)))
    key("keyUp")
    expect_equal((target() - t0) * scale, c(-80, 20), tolerance = 0.01)

    # A polygon being clicked out keeps its vertices across a hold
    br$js("window.__giottolens.actions.setMode('poly')")
    click <- function(p) for (t in c("mousePressed", "mouseReleased")) br$session$Input$dispatchMouseEvent(
        type = t, x = p[1], y = p[2], button = "left", buttons = if (t == "mousePressed") 1L else 0L, clickCount = 1L)
    off <- unlist(canvas_rect(br))
    click(off + c(cx, cy)); click(off + c(cx + 30, cy))
    expect_true(browser_wait(br, "window.__giottolens.state.drawRing.length === 2"))
    key("keyDown"); key("keyUp")
    expect_identical(br$js("window.__giottolens.state.drawRing.length"), 2L)
    expect_identical(mode(), "poly")
    expect_no_browser_errors(br)
})

test_that("the middle button pans with any tool without interrupting it", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    off <- unlist(canvas_rect(br, centre = TRUE))
    vs <- function() br$js("(() => { const v = window.__giottolens.spatial.viewState; return [v.target[0], v.target[1], 2 ** v.zoom]; })()")
    mouse <- function(type, p, button = "left") br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = button, buttons = if (type == "mouseReleased") 0L else if (button == "middle") 4L else 1L, clickCount = 1L)
    middle_drag <- function(from, by) {
        mouse("mouseMoved", from); mouse("mousePressed", from, "middle")
        for (f in c(0.5, 1)) mouse("mouseMoved", from + by * f, "middle")
        mouse("mouseReleased", from + by, "middle")
    }
    # The content follows the pointer exactly, with the pan tool too (deck.gl
    # does not pan as well)
    for (tool in c("pan", "lasso")) {
        br$js(sprintf("window.__giottolens.actions.setMode('%s')", tool))
        a <- unlist(vs())
        middle_drag(off, c(40, 20))
        b <- unlist(vs())
        expect_equal(c(b[1] - a[1], b[2] - a[2]) * a[3], c(-40, 20), tolerance = 0.01, info = tool)
    }
    expect_length(v$selection, 0L)

    # A ruler with its first point placed carries on across a pan
    br$js("window.__giottolens.actions.setMode('ruler')")
    click <- function(p) { mouse("mousePressed", p); mouse("mouseReleased", p) }
    click(off)
    expect_true(browser_wait(br, "!!window.__giottolens.state.rulerStart"))
    start <- unlist(br$js("window.__giottolens.state.rulerStart"))
    middle_drag(off + c(10, 10), c(-60, 0))
    expect_identical(unlist(br$js("window.__giottolens.state.rulerStart")), start)
    expect_false(br$js("window.__giottolens.state.rulerLocked"))
    click(off + c(30, 0))
    expect_true(browser_wait(br, "window.__giottolens.state.rulerLocked === true"))
    end <- unlist(br$js("window.__giottolens.state.rulerEnd"))
    expect_equal((end[1] - start[1]) * unlist(vs())[3], 90, tolerance = 0.01)   # 30 px + the 60 px pan
    expect_identical(br$js("window.__giottolens.store.getState().mode"), "ruler")
    expect_no_browser_errors(br)
})

test_that("a release outside the page ends pans and lassos (no sticky drags)", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "/ready|loaded/.test(document.getElementById('status').textContent)"))
    c0 <- canvas_rect(br, centre = TRUE)
    x0 <- c0[[1]]; y0 <- c0[[2]]
    send <- function(type, x, y, buttons) br$session$Input$dispatchMouseEvent(type = type,
        x = x, y = y, button = if (buttons) "left" else "none", buttons = buttons, clickCount = 1L)
    target <- function() unlist(br$js("window.__giottolens.spatial.viewState.target.slice(0, 2)"))

    # A normal drag pans
    t0 <- target()
    send("mouseMoved", x0, y0, 0L); send("mousePressed", x0, y0, 1L)
    for (s in 1:5) send("mouseMoved", x0 + 20 * s, y0, 1L)
    send("mouseReleased", x0 + 100, y0, 0L)
    t1 <- target()
    expect_false(isTRUE(all.equal(t0, t1)))

    # Released outside the page: the next moves arrive with no button down
    send("mousePressed", x0, y0, 1L)
    for (s in 1:5) send("mouseMoved", x0 + 20 * s, y0, 1L)
    t2 <- target()
    for (s in 1:5) send("mouseMoved", x0 - 20 * s, y0 + 10 * s, 0L)
    expect_equal(target(), t2)

    # Same for a lasso: it completes instead of following the pointer
    set_tool(br, "lasso")
    send("mousePressed", x0, y0, 1L)
    for (a in seq(0, 2 * pi, length.out = 12)) send("mouseMoved", x0 + 80 * cos(a), y0 + 80 * sin(a), 1L)
    send("mouseMoved", x0 + 200, y0 + 200, 0L)
    expect_true(browser_wait(br, "window.__giottolens.state.lassoActive === false"))
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_no_browser_errors(br)
})

test_that("set_view sets the zoom after the view was zoomed by hand", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br,
        "!!document.querySelector('.r-status.connected')"))
    zoom <- function() br$js("window.__giottolens.spatial.deck.getViewports()[0].zoom")
    z0 <- zoom()

    # A wheel on the canvas zooms through deck.gl's controller
    r <- canvas_rect(br, centre = TRUE)
    br$session$Input$dispatchMouseEvent(type = "mouseWheel", x = r[[1]], y = r[[2]],
        deltaX = 0, deltaY = -500)
    expect_true(browser_wait(br, sprintf(
        "Math.abs(window.__giottolens.spatial.deck.getViewports()[0].zoom - %f) > 0.1", z0)))

    v$set_view(zoom = z0 - 1)
    expect_true(browser_wait(br, sprintf(
        "Math.abs(window.__giottolens.spatial.deck.getViewports()[0].zoom - %f) < 1e-6", z0 - 1)))
    # The box fits the view, its tighter side 2^0.2 times the box's
    v$set_view(bounds = c(0, 50, -50, 0))
    b <- v$view_bounds()
    expect_true(b[["xmin"]] <= 0 && b[["xmax"]] >= 50 && b[["ymin"]] <= -50 && b[["ymax"]] >= 0)
    expect_equal(min(b[["xmax"]] - b[["xmin"]], b[["ymax"]] - b[["ymin"]]), 50 * 2^0.2, tolerance = 0.01)
    expect_no_browser_errors(br)
})
