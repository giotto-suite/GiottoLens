# Browser: annotations zoomed to, selected from and edited in pan mode

test_that("zoom to an annotation after the view was zoomed by hand", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br,
        "!!document.querySelector('.r-status.connected')"))
    v$push_polygons("POLYGON((5 -95,15 -95,15 -85,5 -85,5 -95))")
    zoom <- function() br$js("window.__giottolens.spatial.deck.getViewports()[0].zoom")
    z0 <- zoom()

    # The controller's view state has maxZoomX/maxZoomY, not maxZoom
    r <- canvas_rect(br, centre = TRUE)
    br$session$Input$dispatchMouseEvent(type = "mouseWheel", x = r[[1]], y = r[[2]],
        deltaX = 0, deltaY = -500)
    expect_true(browser_wait(br, sprintf(
        "Math.abs(window.__giottolens.spatial.deck.getViewports()[0].zoom - %f) > 0.1", z0)))

    tray_show(br, "annotations")
    expect_true(browser_wait(br, "!!document.querySelector('.annot-row-nav')"))
    br$js("document.querySelector('.annot-row-nav').click()")
    expect_true(browser_wait(br,
        "Math.abs(window.__giottolens.spatial.viewState.target[0] - 10) < 1e-6"))
    expect_true(is.finite(zoom()))
    expect_gt(zoom(), z0)
    expect_no_browser_errors(br)
})

test_that("an annotation's select button selects the cells inside it", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    v$push_polygons(c("POLYGON((0 -100,22 -100,22 -78,0 -78,0 -100))",
        "POLYGON((80 -20,100 -20,100 0,80 0,80 -20))"))
    expect_true(pump_until(function() length(v$annotations) == 2L))
    expect_identical(names(v$annotations), c("annotation_1", "annotation_2"))

    tray_show(br, "annotations")
    expect_true(browser_wait(br, "document.querySelectorAll('.annot-row-sel').length === 2"))
    click <- function(i, shift = FALSE) br$js(sprintf(
        "document.querySelectorAll('.annot-row-sel')[%d].dispatchEvent(new MouseEvent('click', { bubbles: true, shiftKey: %s }))",
        i, if (shift) "true" else "false"))
    click(0)
    first <- c("cell_001", "cell_002", "cell_011", "cell_012")
    expect_true(pump_until(function() setequal(v$selection, first)))
    # Shift adds, as with the lasso
    click(1, shift = TRUE)
    expect_true(pump_until(function() setequal(v$selection, c(first, "cell_089", "cell_090", "cell_099", "cell_100"))))

    # Renamed by a double-click on the name in the list. Names are unique: a
    # taken or empty one is marked and changes nothing; a free one is the key
    rename <- function(to) br$js(sprintf("(() => {
        const t = document.querySelectorAll('.annot-row .annot-name-text')[1];
        t.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
        const i = document.querySelector('.annot-row .name-edit');
        i.value = '%s'; i.dispatchEvent(new Event('input')); const bad = i.classList.contains('invalid');
        i.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        return [bad, document.querySelectorAll('.annot-row .annot-name-text')[1].textContent]; })()", to))
    expect_identical(rename("annotation_1"), list(TRUE, "annotation_2"))
    expect_identical(rename(""), list(TRUE, "annotation_2"))
    expect_identical(rename("tumor"), list(FALSE, "tumor"))
    expect_true(pump_until(function() identical(names(v$annotations), c("annotation_1", "tumor"))))
    expect_no_browser_errors(br)
})

test_that("the selected annotation's vertices are dragged, added and removed in pan mode", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    v$push_polygons("POLYGON((20 -80,80 -80,80 -20,20 -20,20 -80))")
    expect_true(pump_until(function() length(v$annotations) == 1L))
    br$js("(() => { const g = window.__giottolens; g.actions.selectAnnotation(g.store.getState().annotations[0].id); })()")
    expect_true(browser_wait(br, "window.__giottolens.spatial.deck.props.layers.some(l => l.id === 'annot-vertices')"))

    # The ring R holds, open; a world point's canvas pixel
    ring <- function() {
        xy <- jsonlite::fromJSON(v$annotations[[1]], simplifyVector = FALSE)$geometry$coordinates[[1]]
        m <- do.call(rbind, lapply(xy, unlist))
        m[-nrow(m), , drop = FALSE]
    }
    px <- function(x, y) unlist(br$js(sprintf(
        "window.__giottolens.spatial.deck.getViewports()[0].project([%f, %f])", x, y)))
    off <- unlist(canvas_rect(br))
    mouse <- function(type, p, count = 1L) br$session$Input$dispatchMouseEvent(type = type,
        x = off[[1]] + p[[1]], y = off[[2]] + p[[2]], button = if (type == "mouseMoved") "none" else "left",
        buttons = if (type == "mousePressed") 1L else 0L, clickCount = count)
    frame <- function() br$js("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
    target <- function() unlist(br$js("window.__giottolens.spatial.viewState.target"))
    # Hover first, as a pointer does: the view stops panning over a handle
    drag <- function(from, to, release = TRUE) {
        mouse("mouseMoved", from); frame()
        mouse("mousePressed", from)
        for (f in c(0.25, 0.5, 1)) br$session$Input$dispatchMouseEvent(type = "mouseMoved",
            x = off[[1]] + from[[1]] + (to[[1]] - from[[1]]) * f, y = off[[2]] + from[[2]] + (to[[2]] - from[[2]]) * f,
            button = "left", buttons = 1L)
        if (release) mouse("mouseReleased", to)
    }
    near <- function(m, x, y) any(abs(m[, 1] - x) < 1 & abs(m[, 2] - y) < 1)
    t0 <- target()

    # A vertex moves, and the view stays put
    drag(px(80, -20), px(90, -10))
    expect_true(pump_until(function() near(ring(), 90, -10)))
    expect_equal(nrow(ring()), 4L)
    expect_equal(target(), t0)

    # A midpoint dragged becomes a vertex
    drag(px(50, -80), px(50, -90))
    expect_true(pump_until(function() nrow(ring()) == 5L))
    expect_true(near(ring(), 50, -90))

    # Escape during a drag puts the vertex back
    drag(px(20, -20), px(10, -10), release = FALSE)
    br$session$Input$dispatchKeyEvent(type = "keyDown", key = "Escape", code = "Escape", windowsVirtualKeyCode = 27L)
    mouse("mouseReleased", px(10, -10))
    frame()
    expect_true(near(ring(), 20, -20))
    expect_false(near(ring(), 10, -10))

    # A double-click removes a vertex, down to a triangle
    dbl <- function(p) {
        mouse("mouseMoved", p); frame()
        for (n in 1:2) { mouse("mousePressed", p, n); mouse("mouseReleased", p, n) }
    }
    dbl(px(50, -90))
    expect_true(pump_until(function() nrow(ring()) == 4L))
    dbl(px(20, -80))
    expect_true(pump_until(function() nrow(ring()) == 3L))
    dbl(px(20, -20))
    frame()
    expect_equal(nrow(ring()), 3L)
    expect_no_browser_errors(br)
})
