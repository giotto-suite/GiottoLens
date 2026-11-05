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
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=histogram] canvas')"))

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

test_that("bins without polygons draw as dots, then squares, and select like cells", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta[, c("cell_ID", "half")])
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    ids <- "window.__giottolens.state.deckgl.props.layers.map(l => l.id)"
    has <- function(id) browser_wait(br, sprintf("%s.includes('%s')", ids, id))

    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    # Bins are 2 units across: 2 px at zoom 0, under a dot; 32 px at zoom 4
    v$set_view(x = 60, y = -60, zoom = 0)
    expect_true(has("cell-centroids"))
    v$set_view(x = 60, y = -60, zoom = 4)
    expect_true(has("cell-squares"))
    # Nothing is read from a store
    tiles <- br$js("performance.getEntriesByType('resource').map(e => e.name).filter(u => /\\/(data|files)\\//.test(u))")
    expect_length(tiles, 0L)

    # A rule from R reaches the page, and a lasso from the page reaches R
    v$select(lens_categories("half", "left"))
    expect_true(browser_wait(br, "document.getElementById('sel-count').textContent.startsWith('450 ')"))
    cells <- arrow::read_parquet(file.path(get("private", v$.__enclos_env__)$session, "cells.parquet"))
    ring  <- rbind(c(40, -85), c(75, -85), c(75, -50), c(40, -50))
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', {source:'spatial',kind:'polygon',space:'spatial',params:{rings:[%s]}})",
        jsonlite::toJSON(ring)))
    br$js("window.__giottolens.actions.setCombine('and')")
    expected <- cells$cell_ID[pip(ring, cells$x, cells$y)]
    expected <- intersect(expected, fx$meta$cell_ID[fx$meta$half == "left"])
    expect_true(pump_until(function() setequal(v$selection, expected)))
    expect_gt(length(expected), 0L)
    expect_identical(br$errors(), character())
})

test_that("the cell mark is set from R, survives a reload, and resets", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    layer <- function() br$js("(() => { const l = window.__giottolens.state.deckgl.props.layers.find(l => l.id.startsWith('cell-')); return l && [l.id, l.props.getRadius ?? l.props.radius]; })()")
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    v$set_view(x = 60, y = -60, zoom = 4)
    expect_true(pump_until(function() identical(layer(), list("cell-squares", 1L))))

    # From R: fields merge onto the launch mark
    v$set_mark(shape = "circle", size = 3)
    expect_true(pump_until(function() identical(layer(), list("cell-circles", 1.5))))
    expect_identical(v$describe()$cells$mark, list(shape = "circle", size = 3, angle = 10))

    # Saved with the viewer's settings: back after a reload
    priv <- get("private", v$.__enclos_env__)
    expect_true(pump_until(function() grepl('"cellMark":{"shape":"circle","size":3}',
        priv$config_json %||% "", fixed = TRUE)))
    br$js("location.reload()")
    Sys.sleep(0.3)
    # The page has the restored setting once it has its config
    expect_true(browser_wait(br, "window.__giottolens?.store.getState().cellMark?.size === 3"))
    expect_true(pump_until(function() v$connected()))
    v$set_view(x = 60, y = -60, zoom = 4)
    expect_true(pump_until(function() identical(layer(), list("cell-circles", 1.5))))

    # Dots, then back to the launch mark
    v$set_mark(show = FALSE)
    expect_true(pump_until(function() identical(layer()[[1]], "cell-centroids")))
    expect_identical(v$describe()$cells$mark, NULL)
    v$set_mark()
    expect_true(pump_until(function() identical(layer(), list("cell-squares", 1L))))
    expect_true(browser_wait(br, "Object.keys(window.__giottolens.store.getState().cellMark).length === 0"))
    expect_identical(br$errors(), character())
})

test_that("segmented cells take a mark when it is turned on", {
    fx <- lens_fixture()
    v  <- launch_lens(NULL, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    ids <- "window.__giottolens.state.deckgl.props.layers.map(l => l.id)"
    expect_true(pump_until(function() v$connected(), 20))
    # Below outline zoom: dots by default
    v$set_view(x = 50, y = -50, zoom = -3)
    expect_true(browser_wait(br, sprintf("%s.includes('cell-centroids')", ids)))
    expect_identical(v$describe()$cells$mark, NULL)
    v$set_mark(show = TRUE)
    expect_true(browser_wait(br, sprintf("%s.includes('cell-circles')", ids)))
    expect_identical(v$describe()$cells$mark$shape, "circle")
    expect_identical(br$errors(), character())
})

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

test_that("push_panel docks a Vega-Lite spec linked to the selection", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.panel('histogram') != null"))

    spec <- list(
        mark = "point",
        params = list(list(name = "brush", select = list(type = "interval"))),
        encoding = list(x = list(field = "score", type = "quantitative"),
                        y = list(field = "rank", type = "quantitative"))
    )
    id <- v$push_panel(spec, data = transform(fx$meta, rank = seq_len(nrow(fx$meta))),
        title = "score", where = "right")
    expect_identical(id, "panel-1")
    expect_true(browser_wait(br, "window.__giottolens.panel('panel-1')?.view != null"))
    p <- v$panels()
    expect_setequal(p$id, c("scatter", "histogram", "panel-1"))
    expect_identical(p$title[p$id == "panel-1"], "score")
    expect_identical(p$kind[p$id == "panel-1"], "spec")
    # "right" with no ref: its own group, beside the others; all in view
    expect_false(p$group[p$id == "panel-1"] %in% p$group[p$id != "panel-1"])
    expect_true(all(p$visible))
    # Issue #3: the chart, axes and titles fit inside the panel
    fits <- br$js("(() => { const a = document.querySelector('[data-panel=\"panel-1\"] .stats-chart-area'), c = a.querySelector('canvas'), v = window.__giottolens.panel('panel-1').view; return c.clientWidth <= a.clientWidth + 1 && c.clientHeight <= a.clientHeight + 1 && v.origin()[0] >= 20 && v.origin()[1] >= 0; })()")
    expect_true(fits)

    # Dragging a brush on the chart selects exactly the cells inside it
    box <- br$js("(() => { const r = document.querySelector('[data-panel=\"panel-1\"] canvas').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
    pt <- function(fx_, fy_) c(box[[1]] + fx_ * box[[3]], box[[2]] + fy_ * box[[4]])
    send <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mouseMoved", pt(0.35, 0.15))   # the pointer enters the chart first
    send("mousePressed", pt(0.35, 0.15))
    for (f in seq(0.4, 0.7, by = 0.05)) send("mouseMoved", pt(f, f))
    send("mouseReleased", pt(0.7, 0.7))
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_identical(names(get("private", v$.__enclos_env__)$rule_set), "panel:panel-1")
    m <- transform(fx$meta, rank = seq_len(nrow(fx$meta)))
    s_ <- m[m$cell_ID %in% v$selection, ]
    inside <- m$score >= min(s_$score) & m$score <= max(s_$score) &
              m$rank >= min(s_$rank) & m$rank <= max(s_$rank)
    expect_setequal(v$selection, m$cell_ID[inside])
    expect_lt(length(v$selection), 100L)

    # A metadata reload keeps the pushed panel
    v$push_metadata(fx$meta)
    Sys.sleep(0.5); later::run_now(0.2)
    expect_true(br$js("window.__giottolens.panel('panel-1')?.view != null"))

    # Pushing to the same id replaces the chart in place; a tab joins its group
    v$push_panel(spec, data = transform(fx$meta, rank = rev(seq_len(nrow(fx$meta)))),
        id = "panel-1", title = "score 2")
    v$push_panel(list(mark = "bar", encoding = list(x = list(field = "a", type = "nominal"))),
        data = data.frame(a = c("x", "y")), id = "bars", ref = "histogram")
    expect_true(browser_wait(br, "window.__giottolens.panel('bars')?.view != null"))
    p <- v$panels()
    expect_identical(p$title[p$id == "panel-1"], "score 2")
    expect_identical(p$group[p$id == "bars"], p$group[p$id == "histogram"])
    expect_false(p$visible[p$id == "histogram"])   # behind the new tab

    v$remove_panel("bars")
    v$remove_panel("scatter")
    expect_true(pump_until(function() setequal(v$panels()$id, c("histogram", "panel-1"))))
    expect_identical(br$errors(), character())
})

test_that("a reload brings back the layout, panels, settings and brushes", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.panel('histogram')?.view != null"))

    spec <- list(mark = "point",
        params = list(list(name = "brush", select = list(type = "interval"))),
        encoding = list(x = list(field = "score", type = "quantitative"),
                        y = list(field = "rank", type = "quantitative")))
    v$push_panel(spec, data = transform(fx$meta, rank = seq_len(nrow(fx$meta))), id = "sc", where = "below")
    expect_true(browser_wait(br, "window.__giottolens.panel('sc')?.view != null"))
    v$remove_panel("scatter")
    v$set_layer("poly", alpha = 0.25)
    v$color_by("leiden_clus")

    # A range from R shows as the histogram's brush
    # A brush's extent, rounded: Vega keeps it through pixel space
    brush_of <- function(id) {
        b <- br$js(sprintf("JSON.stringify(window.__giottolens.panel('%s')?.view?.signal('brush') ?? null)", id))
        if (is.null(b)) return(NULL)
        lapply(jsonlite::fromJSON(b), function(r) round(r, 6))
    }
    v$select(lens_range("score", 3, 6), source = "hist:score")
    expect_true(pump_until(function() identical(brush_of("histogram"), list(bin0 = c(3, 6)))))
    # and a brush dragged on the pushed chart is added to it
    box <- br$js("(() => { const r = document.querySelector('[data-panel=\"sc\"] canvas').getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()")
    pt <- function(fx_, fy_) c(box[[1]] + fx_ * box[[3]], box[[2]] + fy_ * box[[4]])
    send <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mouseMoved", pt(0.3, 0.2)); send("mousePressed", pt(0.3, 0.2))
    for (f in seq(0.35, 0.6, by = 0.05)) send("mouseMoved", pt(f, f))
    send("mouseReleased", pt(0.6, 0.6))
    expect_true(pump_until(function() setequal(v$rules()$source, c("hist:score", "panel:sc"))))
    sc_brush <- brush_of("sc")
    expect_setequal(names(sc_brush), c("score", "rank"))
    n_sel <- length(v$selection)
    before <- v$panels()
    # The page's config has reached R
    priv <- get("private", v$.__enclos_env__)
    expect_true(pump_until(function() grepl('"alpha":0.25', priv$config_json %||% "", fixed = TRUE) &&
        !grepl('"scatter"', priv$config_json, fixed = TRUE)))

    br$js("location.reload()")
    Sys.sleep(0.3)
    expect_true(browser_wait(br, "window.__giottolens?.panel('sc')?.view != null"))
    expect_true(browser_wait(br, "window.__giottolens.panel('histogram')?.view != null"))
    after <- v$panels()
    expect_identical(after$id, before$id)
    expect_identical(after$group == after$group[1], before$group == before$group[1])
    st <- v$state()
    expect_identical(st$config$layers$poly$alpha, 0.25)
    expect_identical(st$config$colorBy, "leiden_clus")
    expect_identical(st$selected, n_sel)
    # Both brushes are drawn again, so they can be dragged on
    expect_true(pump_until(function() identical(brush_of("histogram"), list(bin0 = c(3, 6)))))
    expect_true(pump_until(function() identical(brush_of("sc"), sc_brush)))
    # ...and can be dragged: the range follows the brush
    xy <- br$js("(() => { const v = window.__giottolens.panel('histogram').view, r = v.container().querySelector('canvas').getBoundingClientRect(), o = v.origin().map((z, i) => z + (i ? v.padding().top : v.padding().left)); return [r.left + o[0] + v.scale('x')(4.5), r.top + o[1] + v.height() / 2]; })()")
    p0 <- c(xy[[1]], xy[[2]])
    send("mouseMoved", p0); send("mousePressed", p0)
    for (dx in seq(5, 30, by = 5)) send("mouseMoved", p0 + c(dx, 0))
    send("mouseReleased", p0 + c(30, 0))
    hist_rule <- function() Filter(function(r) identical(r$source, "hist:score"), v$selection_rules)[[1]]
    expect_true(pump_until(function() hist_rule()$params$min > 3.2))
    expect_equal(hist_rule()$params$max - hist_rule()$params$min, 3, tolerance = 1e-6)
    # Dropping the rule elsewhere clears the histogram's brush
    v$select(NULL, source = "hist:score", replace = FALSE)
    expect_true(browser_wait(br, "Object.keys(window.__giottolens.panel('histogram')?.view?.signal('brush') ?? {}).length === 0"))
    expect_identical(br$errors(), character())
})


test_that("the density panel bins two columns, and its rectangle is two ranges", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    m <- transform(fx$meta, umap_1 = score, umap_2 = seq_len(nrow(fx$meta)) / 10)
    suppressMessages(v$push_metadata(m))
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.panel('histogram')?.view != null"))

    # Added from the + menu, titled by its columns
    br$js("document.querySelector('.dock-add').click()")
    br$js("[...document.querySelectorAll('.dock-menu.open button')].find(b => b.textContent === 'density').click()")
    expect_true(browser_wait(br, "window.__giottolens.panel('density')?.view != null"))
    p <- v$panels()
    expect_identical(p$title[p$id == "density"], "umap_1 \u00d7 umap_2")

    # A rectangle from R is drawn as the brush, and selects the cells in both ranges
    box <- function() {
        b <- br$js("JSON.stringify(window.__giottolens.panel('density')?.view?.signal('brush') ?? null)")
        if (is.null(b)) NULL else lapply(jsonlite::fromJSON(b), function(r) round(r, 6))
    }
    rule <- lens_intersect(lens_range("umap_1", 2, 6), lens_range("umap_2", 2, 6))
    v$select(rule, source = "density")
    inside <- function(r) m$cell_ID[m$umap_1 >= r[[1]] & m$umap_1 <= r[[2]] & m$umap_2 >= r[[3]] & m$umap_2 <= r[[4]]]
    expect_setequal(v$selection, inside(c(2, 6, 2, 6)))
    expect_true(pump_until(function() identical(box(), list(x = c(2, 6), y = c(2, 6)))))
    expect_true(any(grepl("lens_intersect(lens_range(", v$rules(code = TRUE), fixed = TRUE)))
    # The bins sit where Vega draws the plot: its origin plus its padding
    expect_true(br$js("(() => { const v = window.__giottolens.panel('density').view, c = v.container().querySelector('svg'),
      t = document.querySelector('[data-panel=density] canvas'),
      cr = c.getBoundingClientRect(), tr = t.getBoundingClientRect(), p = v.padding(), o = v.origin();
      return Math.abs(tr.left - (cr.left + o[0] + p.left)) < 0.5 && Math.abs(tr.top - (cr.top + o[1] + p.top)) < 0.5 &&
        Math.abs(tr.width - v.width()) < 0.5 && Math.abs(tr.height - v.height()) < 0.5; })()"))

    # Dragging the rectangle moves both ranges; the selection follows
    xy <- br$js("(() => { const v = window.__giottolens.panel('density').view, r = v.container().querySelector('svg').getBoundingClientRect(), o = v.origin().map((z, i) => z + (i ? v.padding().top : v.padding().left)); return [r.left + o[0] + v.scale('x')(4), r.top + o[1] + v.scale('y')(4)]; })()")
    p0 <- c(xy[[1]], xy[[2]])
    send <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mouseMoved", p0); send("mousePressed", p0)
    for (d in seq(4, 24, by = 4)) send("mouseMoved", p0 + c(d, -d))
    # While the button is down the drag is live (adr/0013): the count follows
    # the rectangle, and the rule is set only on release
    live <- function() br$js("(() => { const r = window.__giottolens.store.getState().rules.density;
      return [document.getElementById('sel-count').textContent, r.params.parts[0].params.min]; })()")
    expect_true(pump_until(function() { l <- live(); l[[1]] != "" && l[[1]] != paste(length(inside(c(2, 6, 2, 6))), "selected") }))
    expect_equal(live()[[2]], 2)
    send("mouseReleased", p0 + c(24, -24))
    moved <- function() {
        r <- Filter(function(x) identical(x$source, "density"), v$selection_rules)
        if (!length(r)) return(NULL)
        unlist(lapply(r[[1]]$params$parts, function(q) c(q$params$min, q$params$max)))
    }
    expect_true(pump_until(function() { r <- moved(); !is.null(r) && r[[1]] > 2.1 && r[[3]] > 2.1 }))
    r <- moved()
    expect_equal(c(r[[2]] - r[[1]], r[[4]] - r[[3]]), c(4, 4), tolerance = 1e-6)
    expect_true(pump_until(function() setequal(v$selection, inside(r))))

    # The wheel zooms the plot, not the rectangle; Shift+drag pans; the button resets
    dom <- function() unlist(br$js("window.__giottolens.panel('density').view.scale('x').domain()"))
    full <- dom()
    br$session$Input$dispatchMouseEvent(type = "mouseWheel", x = p0[1], y = p0[2], deltaX = 0, deltaY = -300)
    expect_true(pump_until(function() diff(dom()) < diff(full) * 0.9))
    zoomed <- dom()
    expect_identical(moved(), r)
    shift <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2], modifiers = 8L,
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    q0 <- p0 + c(0, 40)
    shift("mouseMoved", q0); shift("mousePressed", q0)
    for (d in seq(10, 60, by = 10)) shift("mouseMoved", q0 + c(d, 0))
    shift("mouseReleased", q0 + c(60, 0))
    expect_true(pump_until(function() dom()[1] < zoomed[1] - 1e-9))
    expect_equal(diff(dom()), diff(zoomed), tolerance = 1e-6)
    expect_identical(moved(), r)
    # The hand tool: a plain drag pans, and leaves the rectangle alone
    tool <- function(t) br$js(sprintf("document.querySelector('[data-panel=density] .stats-controls button[title^=\"%s\"]').click()", t))
    width <- diff(dom())
    tool("pan")
    # Rebuilt for the new tool, at the same zoom
    expect_true(pump_until(function() isTRUE(tryCatch(abs(diff(dom()) - width) < 1e-6 &&
        br$js("window.__giottolens.panel('density')?.view != null"), error = function(e) FALSE))))
    Sys.sleep(0.2); later::run_now(0.1)
    before <- dom()
    send("mouseMoved", q0); send("mousePressed", q0)
    for (d in seq(10, 60, by = 10)) send("mouseMoved", q0 + c(d, 0))
    send("mouseReleased", q0 + c(60, 0))
    expect_true(pump_until(function() dom()[1] < before[1] - 1e-9))
    expect_identical(moved(), r)
    tool("select")
    br$js("document.querySelector('[data-panel=density] .stats-controls button[title^=\"zoom to fit\"]').click()")
    expect_true(pump_until(function() isTRUE(all.equal(dom(), full))))
    expect_true(pump_until(function() { b <- box(); !is.null(b$x) && isTRUE(all.equal(b$x, r[1:2], tolerance = 1e-6)) }))

    # A reload brings the panel and its rectangle back
    br$js("location.reload()")
    Sys.sleep(0.3)
    expect_true(browser_wait(br, "window.__giottolens?.panel('density')?.view != null"))
    expect_true(pump_until(function() { b <- box(); !is.null(b$x) && isTRUE(all.equal(b$x, r[1:2], tolerance = 1e-6)) }))
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

test_that("Shift adds and Alt subtracts with the lasso and brush; R agrees", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    expect_true(pump_until(function() v$connected()))

    priv  <- get("private", v$.__enclos_env__)
    cells <- arrow::read_parquet(file.path(priv$session, "cells.parquet"))
    in_r  <- function() sort(cells$cell_ID[.eval_rule(.resolve_cells(v$selection_rules[[1]], cells$cell_ID),
        list(x = cells$x, y = cells$y))])
    rule_kind <- function() br$js("window.__giottolens.store.getState().rules.spatial?.kind ?? null")
    sel_after <- function(f) { v$selection <- NULL; f(); pump_until(function() !is.null(v$selection)); v$selection }

    br$js("document.querySelector('.tool-btn[data-mode=\"lasso\"]').click()")
    size <- br$js("(() => { const c = document.getElementById('deck-canvas'); return [c.clientWidth, c.clientHeight]; })()")
    w <- size[[1]]; h <- size[[2]]
    box <- function(x0, x1, y0, y1) list(c(x0 * w, y0 * h), c(x1 * w, y0 * h), c(x1 * w, y1 * h), c(x0 * w, y1 * h), c(x0 * w, y0 * h))
    target <- br$js("window.__giottolens.state.currentViewState.target")

    # Shapes stay clear of the overlays at the edges (HUD, rules strip)
    left  <- sel_after(function() browser_drag(br, box(0.2, 0.5, 0.2, 0.8)))
    expect_identical(rule_kind(), "polygon")
    right <- sel_after(function() browser_drag(br, box(0.5, 0.8, 0.2, 0.8)))      # replaces
    expect_length(intersect(left, right), 0L)
    both  <- sel_after(function() browser_drag(br, box(0.2, 0.5, 0.2, 0.8), 8L))  # Shift adds
    expect_identical(rule_kind(), "union")
    expect_setequal(both, union(left, right))
    expect_identical(sort(v$selection), in_r())
    cut <- sel_after(function() browser_drag(br, box(0.2, 0.8, 0.2, 0.5), 1L))    # Alt subtracts
    expect_identical(rule_kind(), "intersect")
    expect_true(length(cut) > 0L && length(cut) < length(both) && all(cut %in% both))
    expect_identical(sort(v$selection), in_r())
    # Modifier drags draw; they do not move the camera
    expect_identical(br$js("window.__giottolens.state.currentViewState.target"), target)

    # A subtracting brush (Ctrl) removes what it covers, the same in R
    br$js("document.querySelector('.tool-btn[data-mode=\"brush\"]').click()")
    brushed <- sel_after(function() browser_drag(br,
        lapply(seq(0.25, 0.75, by = 0.05), function(f) c(f * w, 0.65 * h)), 2L))
    expect_true(length(brushed) < length(cut) && all(brushed %in% cut))
    expect_identical(sort(v$selection), in_r())

    # rules(code = TRUE) rebuilds it with lens_intersect(), the brush as negated cells
    lines <- v$rules(code = TRUE)
    expect_true(any(grepl("lens_intersect(", lines, fixed = TRUE)))
    expect_true(any(grepl("negate = TRUE)", lines, fixed = TRUE)))
    sel <- v$selection
    v$select(NULL)
    viewer <- v
    invisible(capture.output(for (l in lines) eval(parse(text = l))))
    expect_setequal(v$selection, sel)
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

    # × drops one rule; the toggle hides the strip. The rules R just re-sent
    # reach the page on the socket, which can lag this test's own commands
    x_js <- "document.querySelector('#rule-strip .rule-chip[data-source=\"hist:score\"] .rule-chip-x')"
    expect_true(browser_wait(br, sprintf("!!%s && window.__giottolens.store.getState().selection.count === %d",
        x_js, length(sel))))
    br$js(paste0(x_js, ".click()"))
    expect_true(pump_until(function() length(v$selection) > n_both))
    expect_identical(v$rules()$source, "spatial")
    br$js("document.getElementById('btn-rules').click()")
    expect_true(browser_wait(br, "document.getElementById('rule-strip').style.display === 'none'"))
    expect_identical(br$errors(), character())
})

test_that("images draw under the cells in data coordinates, and R sets them", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    loaded <- paste0("(() => { const L = window.__giottolens?.state.deckgl?.layerManager?.getLayers() ?? [];",
        " const im = L.filter(l => /^img-/.test(l.id) && !l.parent);",
        " return im.length === 1 && im.every(l => l.isLoaded); })()")
    expect_true(browser_wait(br, loaded))

    # Pyramid from the COG's overview IFDs; contrast from the smallest level
    img <- br$js("(() => { const i = window.__giottolens.state.images.get('stain');
        return { levels: i.levels.length, width: i.width }; })()")
    expect_identical(img, list(levels = 4L, width = 1200L))
    st <- v$state()$config$images$stain
    expect_true(st$show)
    # (GDAL's overviews resample with cubic overshoot at the quadrant's edge)
    expect_equal(unlist(st$contrast), c(100, 4000), tolerance = 0.1)

    v$set_layer("poly", show = FALSE)
    v$set_image("stain", color = "white", contrast = c(0, 4000))
    expect_identical(unlist(v$state()$config$images$stain$color), c(255L, 255L, 255L))
    expect_error(v$set_image("nope"), "must be one of the viewer's images: stain, he")
    pump_until(function() FALSE, 0.3)
    expect_true(browser_wait(br, loaded))

    # The bright quadrant is the image's first rows and columns: top left
    px <- function(x, y) br$js(sprintf(
        "window.__giottolens.state.deckgl.getViewports()[0].project([%f, %f])", x, y))
    shot <- png::readPNG(v$screenshot())
    at <- function(p) shot[round(p[[2L]]) + 1L, round(p[[1L]]) + 1L, 1L]
    expect_gt(at(px(25, -25)), 0.8)
    expect_lt(at(px(75, -75)), 0.2)
    expect_lt(at(px(75, -25)), 0.2)

    # The contrast thumbs cannot pass each other, by pointer or keyboard
    br$js("(() => { const [lo, hi] = document.querySelectorAll('#img-list .range2 input');
        lo.value = 3000; lo.dispatchEvent(new Event('input'));
        hi.value = 1000; hi.dispatchEvent(new Event('input')); })()")
    ct <- unlist(v$state()$config$images$stain$contrast)
    expect_identical(ct, c(3000L, 3001L))

    # The RGB image is told apart by its TIFF tags: drawn in its own colours,
    # with no colour or contrast to set
    v$set_image("stain", show = FALSE)
    expect_false(v$describe()$images[["stain"]])
    v$set_image("he", show = TRUE)
    he <- v$state()$config$images$he
    expect_true(he$rgb)
    expect_null(he$contrast)
    expect_error(v$set_image("he", contrast = c(0, 10)), "RGB image; it has no colour or contrast")
    expect_true(br$js("document.querySelectorAll('#img-list .img-item')[1].querySelector('.range2') === null"))
    pump_until(function() FALSE, 0.3)
    expect_true(browser_wait(br, loaded))
    shot <- png::readPNG(v$screenshot())
    tl <- shot[round(px(25, -25)[[2L]]) + 1L, round(px(25, -25)[[1L]]) + 1L, 1:3]
    br_ <- shot[round(px(75, -75)[[2L]]) + 1L, round(px(75, -75)[[1L]]) + 1L, 1:3]
    expect_gt(tl[1L], 0.8); expect_lt(tl[3L], 0.2)
    expect_gt(br_[3L], 0.8); expect_lt(br_[1L], 0.2)
    expect_identical(br$errors(), character())
})

test_that("flipped and rotated images are drawn where GiottoClass places them", {
    fx <- lens_image_fixture()
    turned <- GiottoClass::spin(GiottoClass::flip(fx$g@images$stain, direction = "horizontal"),
        30, x0 = 10, y0 = 5)
    turned@name <- "turned"
    g <- suppressMessages(suppressWarnings(GiottoClass::setGiotto(fx$g, turned, verbose = FALSE)))
    v <- launch_lens(g, open = FALSE, images = "turned")
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    loaded <- paste0("(() => { const L = window.__giottolens?.state.deckgl?.layerManager?.getLayers() ?? [];",
        " const im = L.filter(l => /^img-/.test(l.id) && !l.parent);",
        " return im.length === 1 && im.every(l => l.isLoaded); })()")
    expect_true(browser_wait(br, loaded))
    v$set_layer("poly", show = FALSE)
    v$set_image("turned", color = "white", contrast = c(0, 4000))
    v$set_view(bounds = as.vector(terra::ext(turned)))
    pump_until(function() FALSE, 0.3)
    expect_true(browser_wait(br, loaded))

    # Centres of the bright and a dark quadrant, moved as GiottoClass moves points
    at <- GiottoClass:::.affine_matrix(rbind(c(25, -25), c(75, -75)), turned@affine[])
    shot <- png::readPNG(v$screenshot())
    value <- function(xy) {
        p <- br$js(sprintf("window.__giottolens.state.deckgl.getViewports()[0].project([%f, %f])",
            xy[[1L]], xy[[2L]]))
        shot[round(p[[2L]]) + 1L, round(p[[1L]]) + 1L, 1L]
    }
    expect_gt(value(at[1L, ]), 0.8)
    expect_lt(value(at[2L, ]), 0.2)
    expect_identical(br$errors(), character())
})
