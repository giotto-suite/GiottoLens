# Browser: lasso, brush and table selections, their modifiers and rules, and how R sees them

test_that("the cell table shows the other sources' cells, and picks rows into the selection", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    suppressMessages(v$push_metadata(fx$meta[, c("cell_ID", "half", "array_row")]))
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    priv <- lens_priv(v)
    dock_tab(br, "table")
    q <- function(sel) sprintf("document.querySelector('[data-panel=table] %s')", sel)
    count <- function(text) browser_wait(br, sprintf("%s.textContent === '%s'", q(".table-count"), text))
    row_ids <- sprintf("[...document.querySelectorAll('[data-panel=table] .table-rows .table-row')].map(r => r.firstChild.textContent)")
    click <- function(k, mods = "") br$js(sprintf(
        "%s.dispatchEvent(new MouseEvent('click', {bubbles: true%s}))", q(sprintf('.table-rows .table-row[data-row="%d"]', k)), mods))

    # All cells, IDs from R for the rows in view
    expect_true(count("900 cells"))
    expect_true(browser_wait(br, sprintf("%s[0] === '%s'", row_ids, priv$cell_ids[1])))

    # Another source's selection sets the rows
    v$select(lens_categories("half", "left"))
    expect_true(count("450 cells"))
    left <- priv$cell_ids[priv$cell_ids %in% fx$meta$cell_ID[fx$meta$half == "left"]]
    expect_true(browser_wait(br, sprintf("%s[0] === '%s'", row_ids, left[1])))

    # Picks are the table's rule: in "or" mode added to the selection, the rows unchanged
    br$js("window.__giottolens.actions.setCombine('or')")
    click(0)
    click(2, ", shiftKey: true")
    expect_true(count("450 cells \u00b7 3 picked"))
    expect_true(pump_until(function() "table" %in% vapply(v$selection_rules, `[[`, "", "source")))
    expect_identical(length(v$selection), 450L)
    # Cross-filter: the selection narrows to the picks, the rows still the other sources'
    br$js("window.__giottolens.actions.setCombine('and')")
    expect_true(pump_until(function() setequal(v$selection, left[1:3])))
    expect_true(count("450 cells \u00b7 3 picked"))
    click(1, ", metaKey: true")
    expect_true(pump_until(function() setequal(v$selection, left[c(1, 3)])))

    # Scrolled to the end, the last row is the last cell
    br$js(sprintf("(() => { const s = %s; s.scrollTop = s.scrollHeight; s.dispatchEvent(new Event('scroll')); })()",
        q(".table-scroll")))
    expect_true(browser_wait(br, sprintf("%s.at(-1) === '%s'", row_ids, left[450])))

    br$js(sprintf("%s.click()", q(".table-clear")))
    expect_true(pump_until(function() !"table" %in% vapply(v$selection_rules, `[[`, "", "source")))
    expect_no_browser_errors(br)
})

test_that("selections do not depend on what is loaded, and match R", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.meta?.size === 2"))

    cells <- local({ p <- lens_priv(v); arrow::read_parquet(file.path(p$session, p$cells_file)) })
    ring  <- rbind(c(10, -80), c(70, -90), c(60, -20), c(20, -30))
    expected <- sort(cells$cell_ID[pip(ring, cells$x, cells$y)])
    rule_js <- sprintf("{source:'spatial',kind:'polygon',space:'spatial',params:{rings:[%s]}}",
        jsonlite::toJSON(ring))

    # Zoomed far out: no polygon tiles are loaded
    br$js("(() => { const g = window.__giottolens; g.spatial.deck.setProps({viewState: {...g.spatial.viewState, zoom: -6}}); g.state.cache.clear(); })()")
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    expect_true(pump_until(function() length(v$selection) > 0))
    expect_identical(sort(v$selection), expected)
    expect_identical(v$selection_rules[[1]]$kind, "polygon")

    br$js("window.__giottolens.actions.clearSelection()")
    expect_true(pump_until(function() length(v$selection) == 0L))

    # Invert covers every cell, loaded or not
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    expect_true(pump_until(function() length(v$selection) == length(expected)))
    tray_show(br, "selection")
    br$js("document.querySelector('[data-panel=selection] [data-act=invert]').click()")
    expect_true(pump_until(function() length(v$selection) == 100L - length(expected)))

    # Crossfilter: histogram range AND spatial lasso
    br$js("window.__giottolens.actions.clearSelection()")
    br$js("window.__giottolens.actions.setCombine('and')")
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', %s)", rule_js))
    br$js("window.__giottolens.actions.setRule('hist:score', {source:'hist:score',kind:'range',space:'score',params:{min:3,max:6}})")
    both <- sort(intersect(expected, fx$meta$cell_ID[fx$meta$score >= 3 & fx$meta$score <= 6]))
    expect_true(pump_until(function() identical(sort(v$selection), both)))
    expect_true(browser_wait(br, "document.querySelector('[data-panel=selection] [data-act=and]').classList.contains('active')"))

    expect_no_browser_errors(br)
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
    expect_no_browser_errors(br)
})

test_that("Shift adds and Alt subtracts with the lasso and brush; R agrees", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    expect_true(pump_until(function() v$connected()))

    priv  <- lens_priv(v)
    cells <- arrow::read_parquet(file.path(priv$session, priv$cells_file))
    in_r  <- function() sort(cells$cell_ID[.eval_rule(.resolve_cells(v$selection_rules[[1]], cells$cell_ID),
        list(x = cells$x, y = cells$y))])
    rule_kind <- function() br$js("window.__giottolens.store.getState().rules.spatial?.kind ?? null")
    sel_after <- function(f) { v$selection <- NULL; f(); pump_until(function() !is.null(v$selection)); v$selection }

    set_tool(br, "lasso")
    size <- br$js("(() => { const c = window.__giottolens.spatial.canvas; return [c.clientWidth, c.clientHeight]; })()")
    w <- size[[1]]; h <- size[[2]]
    box <- function(x0, x1, y0, y1) list(c(x0 * w, y0 * h), c(x1 * w, y0 * h), c(x1 * w, y1 * h), c(x0 * w, y1 * h), c(x0 * w, y0 * h))
    target <- br$js("window.__giottolens.spatial.viewState.target")

    # Shapes stay clear of the overlays at the edges (HUD, rules strip)
    left  <- sel_after(function() browser_drag(br, box(0.2, 0.5, 0.2, 0.8)))
    expect_gt(length(left), 0L)
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
    expect_identical(br$js("window.__giottolens.spatial.viewState.target"), target)

    # A subtracting brush (Ctrl) removes what it covers, the same in R
    set_tool(br, "brush")
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
    expect_no_browser_errors(br)
})

test_that("rules are visible: a card per source in the viewer, rules() in R", {
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

    # The selection panel: a card per source with its own count
    cards <- function() unlist(br$js("[...document.querySelectorAll('[data-panel=selection] .rule-card')].map(c => c.querySelector('.rule-label').textContent + ' · ' + c.querySelector('.rule-n').textContent)"))
    tray_show(br, "selection")
    expect_true(browser_wait(br, "document.querySelectorAll('[data-panel=selection] .rule-card').length === 2"))
    tab <- v$rules()
    expect_identical(tab$source, c("spatial", "hist:score"))
    expect_true(any(grepl(sprintf("^lasso · %s cells", format(tab$cells[1], big.mark = ",")), cards())))
    expect_true(any(grepl(sprintf("^score 3–6 · %s cells", format(tab$cells[2], big.mark = ",")), cards())))
    expect_output(print(tab), "Combined with AND")
    expect_no_browser_errors(br)
})
