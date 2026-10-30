tiles_loaded <- "/tile\\(s\\) loaded/.test(document.getElementById('status').textContent)"

test_that("viewer boots, lasso selection reaches R, and R selections reach the page", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)

    expect_true(browser_wait(br, tiles_loaded))
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br,
        "document.getElementById('r-status').className === 'connected'"))

    # Transcripts on: tiles go through the Range handler
    br$js("document.getElementById('show-tx').click()")
    expect_true(browser_wait(br, tiles_loaded))

    br$js("document.querySelector('.tool-btn[data-mode=\"lasso\"]').click()")
    size <- br$js("(() => { const c = document.getElementById('deck-canvas'); return [c.clientWidth, c.clientHeight]; })()")
    cx <- size[[1]] / 2; cy <- size[[2]] / 2; r <- min(cx, cy) * 0.5
    ring <- lapply(seq(0, 2 * pi, length.out = 24), function(a) c(cx + r * cos(a), cy + r * sin(a)))
    browser_drag(br, ring)
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_true(all(grepl("^cell_[0-9]{3}$", v$selection)))
    expect_lt(length(v$selection), 100L)

    v$set_selection(c("cell_001", "cell_002", "cell_003"))
    expect_true(browser_wait(br,
        "document.getElementById('sel-count').textContent.startsWith('3 ')"))

    v$push_metadata(fx$meta)
    expect_true(browser_wait(br,
        "document.getElementById('meta-col-select').options.length === 3"))
    expect_true(browser_wait(br, "!!document.querySelector('#stats-body-2 canvas')"))

    # Everything comes from this server: works offline, one DuckDB
    external <- br$js("performance.getEntriesByType('resource').map(e => e.name).filter(u => !u.startsWith(location.origin))")
    expect_length(external, 0L)

    expect_identical(br$errors(), character())
})

test_that("a polygons-only viewer boots without errors", {
    fx <- lens_fixture()
    v  <- launch_lens(NULL, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)

    expect_true(browser_wait(br, tiles_loaded))
    expect_true(br$js("document.getElementById('gene-list').style.display === 'none'"))
    expect_identical(br$errors(), character())
})

test_that("a points-only viewer boots without errors", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)

    expect_true(browser_wait(br, "[...(window.__giottolens?.state.cache.keys() ?? [])].some(k => k.startsWith('transcripts:'))"))
    expect_identical(br$errors(), character())
})

# Even-odd point-in-polygon, the same test the viewer runs
pip <- function(ring, x, y) {
    inside <- logical(length(x))
    n <- nrow(ring)
    j <- n
    for (i in seq_len(n)) {
        xi <- ring[i, 1]; yi <- ring[i, 2]; xj <- ring[j, 1]; yj <- ring[j, 2]
        hit <- ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
        inside <- xor(inside, hit)
        j <- i
    }
    inside
}

test_that("selections do not depend on what is loaded, and match R", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.meta?.size === 2"))

    cells <- arrow::read_parquet(file.path(get("private", v$.__enclos_env__)$session, "cells.parquet"))
    ring  <- rbind(c(10, -80), c(70, -90), c(60, -20), c(20, -30))
    expected <- sort(cells$cell_ID[pip(ring, cells$x, cells$y)])
    rule_js <- sprintf("{source:'spatial',kind:'polygon',space:'spatial',params:{rings:[%s]}}",
        jsonlite::toJSON(ring))

    # Zoomed far out: no polygon tiles are loaded
    br$js("(() => { const g = window.__giottolens; g.state.deckgl.setProps({viewState: {...g.state.currentViewState, zoom: -6}}); g.state.cache.clear(); })()")
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_identical(sort(v$selection), expected)
    expect_identical(v$selection_rules[[1]]$kind, "polygon")

    br$js("window.__giottolens.actions.clearSelection()")
    expect_true(pump_until(function() length(v$selection) == 0L))

    # Invert covers every cell, loaded or not
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    expect_true(pump_until(function() length(v$selection) == length(expected)))
    br$js("document.getElementById('tool-invert-sel').click()")
    expect_true(pump_until(function() length(v$selection) == 100L - length(expected)))

    # Crossfilter: histogram range AND spatial lasso
    br$js("window.__giottolens.actions.clearSelection()")
    br$js("window.__giottolens.actions.setCombine('and')")
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    br$js("window.__giottolens.actions.setRule('hist:score', {source:'hist:score',kind:'range',space:'score',params:{min:3,max:6}})")
    both <- sort(intersect(expected, fx$meta$cell_ID[fx$meta$score >= 3 & fx$meta$score <= 6]))
    expect_true(pump_until(function() identical(sort(v$selection), both)))
    expect_true(browser_wait(br, "document.getElementById('btn-crossfilter').classList.contains('active')"))

    expect_identical(br$errors(), character())
})

test_that("R drives the viewer: select, state, view, colour, screenshot, log", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)

    # Rules resolve in R before any browser connects
    ring <- rbind(c(10, -80), c(70, -90), c(60, -20), c(20, -30))
    sel_r <- v$select(lens_polygon(ring))
    expect_gt(length(sel_r), 0L)
    expect_error(v$state(), "no viewer connected")

    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    # The tab receives the rule on connect and computes the same cells
    expect_true(browser_wait(br, sprintf(
        "window.__giottolens?.store.getState().selection.count === %d", length(sel_r))))

    v$select(lens_range("score", 3, 6), source = "hist", replace = FALSE, combine = "and")
    both <- intersect(sel_r, fx$meta$cell_ID[fx$meta$score >= 3 & fx$meta$score <= 6])
    expect_setequal(v$selection, both)
    expect_true(browser_wait(br, sprintf(
        "window.__giottolens.store.getState().selection.count === %d", length(both))))

    st <- v$state()
    expect_identical(st$n_cells, 100L)
    expect_identical(st$config$combine, "and")
    expect_setequal(names(st$config$rules), c("r", "hist"))

    vw <- v$set_view(x = 50, y = -50, zoom = 3)
    expect_equal(unlist(vw$target), c(50, -50))
    v$color_by("leiden_clus")
    expect_identical(v$state()$config$colorBy, "leiden_clus")
    expect_error(v$color_by("nope"), "no metadata column")
    v$set_layer("tx", show = TRUE)
    v$show_genes(c("Actb", "Cd3e"))

    png <- v$screenshot()
    expect_true(file.exists(png))
    expect_identical(readBin(png, "raw", 4L), as.raw(c(0x89, 0x50, 0x4e, 0x47)))

    br$js("window.__giottolens.actions.clearSelection()")
    expect_true(pump_until(function() length(v$selection) == 0L))
    lg <- v$log()
    expect_true(all(c("color_by", "clear") %in% lg$action))

    expect_identical(br$errors(), character())
})

test_that("push_panel shows a Vega-Lite spec linked to the selection", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.panels[1] != null"))

    spec <- list(
        mark = "point",
        params = list(list(name = "brush", select = list(type = "interval"))),
        encoding = list(x = list(field = "score", type = "quantitative"),
                        y = list(field = "rank", type = "quantitative"))
    )
    v$push_panel(spec, data = transform(fx$meta, rank = seq_len(nrow(fx$meta))), title = "score")
    expect_true(browser_wait(br, "window.__giottolens.panels[1]?.view != null"))
    expect_true(browser_wait(br,
        "document.querySelector('#stats-pane-2 .stats-pane-title').textContent === 'score'"))
    # Issue #3: the chart, axes and titles fit inside the pane
    fits <- br$js("(() => { const a = document.querySelector('#stats-body-2 .stats-chart-area'), c = a.querySelector('canvas'), v = window.__giottolens.panels[1].view; return c.clientWidth <= a.clientWidth + 1 && c.clientHeight <= a.clientHeight + 1 && v.origin()[0] >= 20 && v.origin()[1] >= 0; })()")
    expect_true(fits)

    # Dragging a brush on the chart selects exactly the cells inside it
    box <- br$js("(() => { const r = document.querySelector('#stats-body-2 canvas').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
    pt <- function(fx_, fy_) c(box[[1]] + fx_ * box[[3]], box[[2]] + fy_ * box[[4]])
    send <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mouseMoved", pt(0.35, 0.15))   # the pointer enters the chart first
    send("mousePressed", pt(0.35, 0.15))
    for (f in seq(0.4, 0.7, by = 0.05)) send("mouseMoved", pt(f, f))
    send("mouseReleased", pt(0.7, 0.7))
    expect_true(pump_until(function() length(v$selection) > 0))
    m <- transform(fx$meta, rank = seq_len(nrow(fx$meta)))
    s_ <- m[m$cell_ID %in% v$selection, ]
    inside <- m$score >= min(s_$score) & m$score <= max(s_$score) &
              m$rank >= min(s_$rank) & m$rank <= max(s_$rank)
    expect_setequal(v$selection, m$cell_ID[inside])
    expect_lt(length(v$selection), 100L)

    # A metadata reload keeps the pushed panel
    v$push_metadata(fx$meta)
    Sys.sleep(0.5); later::run_now(0.2)
    expect_true(br$js("document.querySelector('#stats-pane-2 .stats-pane-title').textContent === 'score'"))
    expect_identical(br$errors(), character())
})


test_that("both tile transfer modes load the same transcripts", {
    fx <- lens_fixture()
    counts <- list()
    for (mode in c("whole", "columns")) {
        v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE, transfer = mode)
        br <- lens_browser(v$url)
        expect_true(browser_wait(br, "/ready|loaded/.test(document.getElementById('status').textContent)"))
        br$js("window.__giottolens.actions.setLayer('tx', {show: true})")
        expect_true(browser_wait(br, "(() => { const s = window.__giottolens.state; return s.pending.size === 0 && [...s.cache.keys()].some(k => k.startsWith('transcripts:')); })()"))
        counts[[mode]] <- br$js("(() => { let n = 0; for (const [k, v] of window.__giottolens.state.cache) if (k.startsWith('transcripts:')) n += v.geneIdxs.length; return n; })()")
        # Polygon tiles are fetched on the page (transcripts in workers, whose
        # requests the page's resource timing does not list)
        urls <- unlist(br$js("performance.getEntriesByType('resource').map(e => e.name).filter(u => /\\/(data|files)\\/polygons\\//.test(u))"))
        expect_gt(length(urls), 0L)
        if (mode == "whole") expect_true(all(grepl("/lens/[^/]+/files/polygons/", urls)))
        else expect_true(all(grepl("/lens/[^/]+/data/polygons/", urls)))
        expect_identical(br$errors(), character())
        br$close(); v$close()
    }
    expect_identical(counts$whole, counts$columns)
    expect_gt(counts$whole, 0)
})

test_that("a release outside the page ends pans and lassos (no sticky drags)", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "/ready|loaded/.test(document.getElementById('status').textContent)"))
    c0 <- br$js("(() => { const r = document.getElementById('deck-canvas').getBoundingClientRect(); return [r.left + r.width/2, r.top + r.height/2]; })()")
    x0 <- c0[[1]]; y0 <- c0[[2]]
    send <- function(type, x, y, buttons) br$session$Input$dispatchMouseEvent(type = type,
        x = x, y = y, button = if (buttons) "left" else "none", buttons = buttons, clickCount = 1L)
    target <- function() unlist(br$js("window.__giottolens.state.currentViewState.target.slice(0, 2)"))

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
    br$js("document.querySelector('.tool-btn[data-mode=\"lasso\"]').click()")
    send("mousePressed", x0, y0, 1L)
    for (a in seq(0, 2 * pi, length.out = 12)) send("mouseMoved", x0 + 80 * cos(a), y0 + 80 * sin(a), 1L)
    send("mouseMoved", x0 + 200, y0 + 200, 0L)
    expect_true(browser_wait(br, "window.__giottolens.state.lassoActive === false"))
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_identical(br$errors(), character())
})

test_that("agent helpers: describe, wait_for_selection, zoom_to, view_bounds, subset", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)

    d0 <- v$describe()
    expect_false(d0$connected)
    expect_identical(d0$n_cells, 100L)
    expect_output(print(d0), "not connected")

    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br, "window.__giottolens?.state.meta?.size === 2"))

    # The "user" lassos half a second after the agent starts waiting
    br$js("setTimeout(() => window.__giottolens.actions.setRule('spatial', {source:'spatial',kind:'polygon',space:'spatial',params:{rings:[[[0,-50],[50,-50],[50,0],[0,0]]]}}), 500); true")
    sel <- v$wait_for_selection(timeout = 20)
    expect_gt(length(sel), 0L)
    expect_identical(sel, v$selection)

    d <- v$describe(by = "leiden_clus")
    expect_true(d$connected)
    expect_identical(d$selected, length(sel))
    expect_identical(sum(d$breakdown), length(sel))
    expect_identical(unname(d$rules), "polygon")
    expect_output(print(d), "selection by leiden_clus")

    # Zoom to the selection, then "select what is on screen" covers it
    v$zoom_to()
    b <- v$view_bounds()
    expect_named(b, c("xmin", "xmax", "ymin", "ymax"))
    expect_true(b[["xmax"]] <= 75)
    v$select(lens_bbox(b))
    expect_true(all(sel %in% v$selection))
    expect_identical(v$describe()$in_view, length(v$selection))

    # Back as a Giotto object
    skip_if_not_installed("GiottoClass")
    m <- matrix(rpois(300, 3), nrow = 3, dimnames = list(c("g1", "g2", "g3"), fx$meta$cell_ID))
    g <- suppressMessages(suppressWarnings(GiottoClass::createGiottoObject(expression = m, verbose = FALSE)))
    gs <- suppressMessages(suppressWarnings(v$subset(g)))
    expect_setequal(GiottoClass::spatIDs(gs), v$selection)
    expect_identical(br$errors(), character())
})

test_that("rules are visible: strip in the viewer, rules() and rules(code = TRUE) in R", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.meta?.size === 2"))

    ring <- rbind(c(10, -80), c(70, -90), c(60, -20), c(20, -30))
    v$select(lens_polygon(ring), source = "spatial", combine = "and")
    v$select(lens_range("score", 3, 6), source = "hist:score", replace = FALSE)
    n_both <- length(v$selection)

    # Strip: one chip per source with its own count, plus AND
    chips <- function() unlist(br$js("[...document.querySelectorAll('#rule-strip .rule-chip')].map(c => c.textContent)"))
    expect_true(browser_wait(br, "document.querySelectorAll('#rule-strip .rule-chip').length === 3"))
    tab <- v$rules()
    expect_identical(tab$source, c("spatial", "hist:score"))
    expect_true(any(grepl(sprintf("^lasso · %d", tab$cells[1]), chips())))
    expect_true(any(grepl(sprintf("^score 3–6 · %d", tab$cells[2]), chips())))
    expect_true("AND" %in% chips())
    expect_output(print(tab), "Combined with AND")

    # The code recreates the selection
    sel <- v$selection
    code <- capture.output(lines <- v$rules(code = TRUE))
    v$select(NULL)
    expect_length(v$selection, 0L)
    viewer <- v
    for (l in lines) eval(parse(text = l))
    expect_setequal(v$selection, sel)

    # × drops one rule; the toggle hides the strip
    br$js("document.querySelector('#rule-strip .rule-chip[data-source=\"hist:score\"] .rule-chip-x').click()")
    expect_true(pump_until(function() length(v$selection) > n_both))
    expect_identical(v$rules()$source, "spatial")
    br$js("document.getElementById('btn-rules').click()")
    expect_true(browser_wait(br, "document.getElementById('rule-strip').style.display === 'none'"))
    expect_identical(br$errors(), character())
})
