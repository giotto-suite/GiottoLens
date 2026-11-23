# Browser: dock panels (pushed Vega-Lite, density, histogram) and what a reload restores

test_that("push_panel docks a Vega-Lite spec linked to the selection", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.panel('scatter') != null"))

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
    expect_setequal(p$id, c("spatial", "scatter", "table", "panel-1", "layers"))
    expect_identical(p$title[p$id == "panel-1"], "score")
    expect_identical(p$kind[p$id == "panel-1"], "spec")
    # "right" with no ref: its own group, beside the others; the charts in view
    expect_false(p$group[p$id == "panel-1"] %in% p$group[p$id != "panel-1"])
    expect_true(all(p$visible[p$id %in% c("scatter", "table", "panel-1")]))
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
    expect_identical(names(lens_priv(v)$rule_set), "panel:panel-1")
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
        data = data.frame(a = c("x", "y")), id = "bars", ref = "table")
    expect_true(browser_wait(br, "window.__giottolens.panel('bars')?.view != null"))
    p <- v$panels()
    expect_identical(p$title[p$id == "panel-1"], "score 2")
    expect_identical(p$group[p$id == "bars"], p$group[p$id == "table"])
    expect_false(p$visible[p$id == "table"])   # behind the new tab

    v$remove_panel("bars")
    v$remove_panel("scatter")
    expect_true(pump_until(function() setequal(v$panels()$id, c("spatial", "table", "panel-1", "layers"))))
    expect_no_browser_errors(br)
})

test_that("a reload brings back the layout, panels, settings and brushes", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    dock_add(br, "histogram")
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
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"alpha":0.25', priv$config_json %||% "", fixed = TRUE) &&
        !grepl('"scatter"', priv$config_json, fixed = TRUE)))

    browser_reload(br)
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
    # A middle drag leaves the brush alone (Vega-Lite's default takes any button)
    middle <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "middle", buttons = if (type == "mouseReleased") 0L else 4L, clickCount = 1L)
    middle("mouseMoved", p0); middle("mousePressed", p0)
    for (dx in seq(5, 30, by = 5)) middle("mouseMoved", p0 + c(dx, 0))
    middle("mouseReleased", p0 + c(30, 0))
    Sys.sleep(0.2); later::run_now(0.1)
    expect_identical(brush_of("histogram"), list(bin0 = c(3, 6)))
    send("mouseMoved", p0); send("mousePressed", p0)
    for (dx in seq(5, 30, by = 5)) send("mouseMoved", p0 + c(dx, 0))
    send("mouseReleased", p0 + c(30, 0))
    hist_rule <- function() Filter(function(r) identical(r$source, "hist:score"), v$selection_rules)[[1]]
    expect_true(pump_until(function() hist_rule()$params$min > 3.2))
    expect_equal(hist_rule()$params$max - hist_rule()$params$min, 3, tolerance = 1e-6)
    # Dropping the rule elsewhere clears the histogram's brush
    v$select(NULL, source = "hist:score", replace = FALSE)
    expect_true(browser_wait(br, "Object.keys(window.__giottolens.panel('histogram')?.view?.signal('brush') ?? {}).length === 0"))
    expect_no_browser_errors(br)
})

test_that("the density panel bins two columns, and its rectangle is two ranges", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    m <- transform(fx$meta, umap_1 = score, umap_2 = seq_len(nrow(fx$meta)) / 10)
    suppressMessages(v$push_metadata(m))
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=scatter]')"))

    # Added from the + menu, titled by its columns
    br$js("[...document.querySelectorAll('.dock-add')].find(b => b.offsetParent).click()")
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
    # The middle button pans too, starting on the rectangle, and leaves it alone
    middle <- function(type, p) br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = "middle", buttons = if (type == "mouseReleased") 0L else 4L, clickCount = 1L)
    before <- dom()
    middle("mouseMoved", p0); middle("mousePressed", p0)
    for (d in seq(10, 60, by = 10)) middle("mouseMoved", p0 + c(d, 0))
    middle("mouseReleased", p0 + c(60, 0))
    expect_true(pump_until(function() dom()[1] < before[1] - 1e-9))
    expect_equal(diff(dom()), diff(zoomed), tolerance = 1e-6)
    expect_identical(moved(), r)
    # The hand tool: a plain drag pans, and leaves the rectangle alone
    tool <- function(t) br$js(sprintf("document.querySelector('[data-panel=density] .chart-tools button[title^=\"%s\"]').click()", t))
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
    br$js("document.querySelector('[data-panel=density] .chart-tools button[title^=\"zoom to fit\"]').click()")
    expect_true(pump_until(function() isTRUE(all.equal(dom(), full))))
    expect_true(pump_until(function() { b <- box(); !is.null(b$x) && isTRUE(all.equal(b$x, r[1:2], tolerance = 1e-6)) }))

    # A reload brings the panel and its rectangle back
    browser_reload(br)
    expect_true(browser_wait(br, "window.__giottolens?.panel('density')?.view != null"))
    expect_true(pump_until(function() { b <- box(); !is.null(b$x) && isTRUE(all.equal(b$x, r[1:2], tolerance = 1e-6)) }))
    expect_no_browser_errors(br)
})
