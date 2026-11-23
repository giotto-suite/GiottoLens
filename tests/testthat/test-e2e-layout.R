# Browser: the control tray, docking the spatial view, split panes and modules

test_that("the tray shows the control picked last; folded, it stays so after a reload", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=layers] [data-layer=poly] .alpha')"))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    expect_true(pump_until(function() v$connected()))

    # The tools bar at the left edge, the spatial view, the scatter with the
    # table below it; in the tray beside the dock, one control: layers, the
    # first
    p <- v$panels()
    expect_identical(p$id, c("spatial", "scatter", "table", "layers"))
    expect_identical(p$kind, p$id)
    expect_identical(length(unique(p$group[1:3])), 3L)
    expect_identical(p$group[4], "tray")
    expect_identical(p$visible, c(TRUE, TRUE, TRUE, TRUE))
    width <- br$js("document.querySelector('.tray-sections').getBoundingClientRect().width")
    expect_equal(width, 260, tolerance = 2)
    expect_identical(unlist(br$js("[...document.querySelectorAll('.tray-rail [data-tray]')].filter(b => b.offsetParent).map(b => b.dataset.tray)")),
        c("layers", "selection", "annotations"))
    # The layers panel: a section per layer, only the cells' open; a
    # section opens and closes from its header, and stays so
    sections <- "[...document.querySelectorAll('[data-panel=layers] .layer-section')].map(e => e.dataset.section + (e.classList.contains('collapsed') ? '-' : '+'))"
    expect_identical(unlist(br$js(sections)), c("cells+", "transcripts-", "images-", "annotations-"))
    tray_show(br, "layers", "transcripts")
    br$js("document.querySelector('[data-section=cells] .layer-toggle').click()")
    expect_identical(unlist(br$js(sections)), c("cells-", "transcripts+", "images-", "annotations-"))
    br$js("document.querySelector('[data-section=cells] .layer-toggle').click()")
    # A rail click shows that control beside the one shown, which keeps its
    # state; a click on a shown one hides it, and with none shown the tray
    # stays open with a note
    shown <- function(k) isTRUE(br$js(sprintf("!!document.querySelector('[data-panel=%s]')?.offsetParent", k)))
    open <- "document.getElementById('tray').classList.contains('open')"
    tray_show(br, "selection")
    expect_true(shown("layers"))
    expect_identical(utils::tail(v$panels()$id, 2L), c("layers", "selection"))
    br$js("document.querySelector('.tray-rail [data-tray=selection]').click()")
    expect_true(browser_wait(br, "!document.querySelector('[data-panel=selection]')?.offsetParent"))
    expect_false("selection" %in% v$panels()$id)
    br$js("document.querySelector('.tray-rail [data-tray=layers]').click()")
    expect_true(browser_wait(br, sprintf("%s && !!document.querySelector('.tray-empty')?.offsetParent", open)))
    expect_false(any(v$panels()$group == "tray"))
    tray_show(br, "layers")
    expect_identical(unlist(br$js(sections)), c("cells+", "transcripts+", "images-", "annotations-"))
    # The + menu offers views only
    br$js("[...document.querySelectorAll('.dock-add')].find(b => b.offsetParent).click()")
    expect_identical(unlist(br$js("[...document.querySelectorAll('.dock-menu.open button')].map(b => b.textContent)")),
        c("spatial", "scatter", "histogram", "density", "table"))
    br$js("document.body.click()")

    # The cells panel waits for metadata, then colours by a column
    expect_true(br$js("getComputedStyle(document.querySelector('[data-section=cells] .panel-note')).display !== 'none'"))
    v$push_metadata(fx$meta)
    expect_true(browser_wait(br, "document.querySelector('[data-section=cells] .color-by').options.length === 3"))
    br$js("(() => { const s = document.querySelector('[data-section=cells] .color-by'); s.value = 'leiden_clus'; s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function() identical(v$state()$config$colorBy, "leiden_clus")))
    expect_true(browser_wait(br, "document.querySelectorAll('[data-section=cells] .legend-item').length > 0"))
    v$color_by(NULL)
    expect_true(browser_wait(br, "document.querySelector('[data-section=cells] .color-by').value === ''"))
    # The layers panel follows set_layer()
    v$set_layer("poly", alpha = 0.3)
    expect_true(browser_wait(br, "document.querySelector('[data-panel=layers] [data-layer=poly] .alpha').value === '30'"))

    # The selection panel: and/or, invert, clear, and the rules as cards
    expect_false(br$js("!!document.querySelector('[data-panel=tools] [data-act=invert]')"))
    tray_show(br, "selection")
    sel <- function(act) br$js(sprintf("document.querySelector('[data-panel=selection] [data-act=%s]').click()", act))
    sel("or")
    expect_true(pump_until(function() identical(lens_priv(v)$combine, "or")))
    expect_true(br$js("document.querySelector('[data-panel=selection] [data-act=or]').classList.contains('active')"))
    sel("and")

    # The table's filter: a metadata rule of its own (`meta`), which narrows
    # the table's rows; "replace" sets one condition, "add" another
    dock_tab(br, "table")
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=table] .table-filter')"))
    filter <- function(col, op, val, act) {
        br$js("document.querySelector('[data-panel=table] .table-filter').click()")
        br$js(sprintf("(() => { const f = document.querySelector('.table-filter-panel.visible');
          f.querySelector('.filter-col').value = '%s'; f.querySelector('.filter-op').value = '%s';
          f.querySelector('.filter-val').value = '%s'; f.querySelector('.filter-%s').click(); })()", col, op, val, act))
        br$js("document.body.click()")
    }
    rows <- "document.querySelectorAll('[data-panel=table] .table-rows .table-row').length"
    filter("score", ">", "5", "replace")
    n_high <- sum(fx$meta$score > 5)
    expect_true(pump_until(function() length(v$selection) == n_high))
    expect_identical(v$rules()$source, "meta")
    expect_true(br$js("document.querySelector('[data-panel=table] .table-filter').classList.contains('active')"))
    filter("score", "<", "8", "add")
    n_mid <- sum(fx$meta$score > 5 & fx$meta$score < 8)
    expect_true(pump_until(function() length(v$selection) == n_mid))
    expect_identical(v$selection_rules[[1]]$kind, "intersect")
    expect_true(browser_wait(br, sprintf("document.querySelector('[data-panel=selection] .rule-card[data-source=meta] .rule-n').textContent === '%d cells'", n_mid)))
    # Rows picked in the table are the table's own rule, beside the filter
    br$js("document.querySelector('[data-panel=table] .table-rows .table-row').click()")
    expect_true(pump_until(function() setequal(v$rules()$source, c("meta", "table"))))
    expect_true(pump_until(function() length(v$selection) == 1L))
    expect_true(browser_wait(br, sprintf("%s >= %d", rows, min(n_mid, 10))))
    # × on a card drops that rule; clear filter drops the filter only
    br$js("document.querySelector('[data-panel=selection] .rule-card[data-source=table] .rule-x').click()")
    expect_true(pump_until(function() identical(v$rules()$source, "meta")))
    sel("invert")
    expect_true(pump_until(function() length(v$selection) == nrow(fx$meta) - n_mid))
    sel("clear")
    expect_true(pump_until(function() length(v$selection) == 0L))
    filter("score", ">", "5", "replace")
    expect_true(pump_until(function() identical(v$rules()$source, "meta")))
    br$js("document.querySelector('[data-panel=table] .table-filter').click()")
    br$js("document.querySelector('.table-filter-panel.visible .filter-clear').click()")
    expect_true(pump_until(function() length(v$selection) == 0L))
    br$js("document.body.click()")
    expect_true(browser_wait(br, "document.querySelector('[data-panel=selection] .rule-empty') !== null"))

    # A chart pushed without a ref joins the charts
    v$push_panel(list(mark = "bar", encoding = list(x = list(field = "a", type = "nominal"))),
        data = data.frame(a = c("x", "y")), id = "bars")
    expect_true(browser_wait(br, "window.__giottolens.panel('bars')?.view != null"))
    p <- v$panels()
    expect_true(p$group[p$id == "bars"] %in% p$group[p$id %in% c("scatter", "table")])

    # Annotations: names on the view and outline settings, from the section
    # or from R
    v$push_polygons("POLYGON ((0 0, 30 0, 30 30, 0 30, 0 0))", names = "a1")
    expect_true(browser_wait(br, "window.__giottolens.store.getState().annotations.length === 1"))
    layer_ids <- "window.__giottolens.spatial.deck.props.layers.map(l => l.id)"
    expect_false("annotation-names" %in% unlist(br$js(layer_ids)))
    tray_show(br, "layers", "annotations")
    br$js("(() => { const c = document.querySelector('[data-section=annotations] .annot-names'); c.click(); })()")
    expect_true(browser_wait(br, sprintf("%s.includes('annotation-names')", layer_ids)))
    v$set_annotation_style(color = "white", width = 4, names = FALSE)
    expect_true(browser_wait(br, "document.querySelector('[data-section=annotations] .outline-color').value === '#ffffff'"))
    expect_true(browser_wait(br, sprintf("!%s.includes('annotation-names')", layer_ids)))
    expect_identical(v$state()$config$annotOutline$width, 4L)
    expect_error(v$set_annotation_style(names = NA), "TRUE or FALSE")

    # remove_panel() of a control hides it, the tray staying open; the
    # controls shown and the fold stay after a reload, and a rail click opens
    # it on the control picked, with its sections as they were left
    tray_show(br, "selection")
    v$remove_panel("selection")
    expect_true(browser_wait(br, sprintf("%s && !document.querySelector('[data-panel=selection]')?.offsetParent", open)))
    br$js("document.querySelector('.tray-fold').click()")
    expect_true(browser_wait(br, sprintf("!%s", open)))
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"trayShown":{"":["layers"]}', priv$config_json %||% "", fixed = TRUE) &&
        grepl('"trayCollapsed":true', priv$config_json, fixed = TRUE)))
    browser_reload(br)
    expect_true(browser_wait(br, sprintf(paste("!!document.querySelector('.r-status.connected')",
        "&& window.__giottolens.store.getState().trayCollapsed && !%s"), open)))
    expect_false(any(v$panels()$group == "tray"))
    tray_show(br, "layers")
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=layers] [data-layer=poly] .alpha')"))
    expect_identical(unlist(br$js(sections)), c("cells+", "transcripts+", "images-", "annotations+"))

    # The arrow folds and opens it too
    br$js("document.querySelector('.tray-fold').click()")
    expect_true(browser_wait(br, sprintf("!%s", open)))
    br$js("document.querySelector('.tray-fold').click()")
    expect_true(browser_wait(br, sprintf("%s && !!document.querySelector('[data-panel=layers]')?.offsetParent", open)))
    expect_no_browser_errors(br)
})

test_that("the spatial view docks: it closes, comes back, and the panels hide beside it", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 1400, height = 800)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    expect_true(pump_until(function() v$connected()))
    width <- function(id) br$js(sprintf("document.querySelector('[data-panel=%s]').clientWidth", id))
    dock <- function() br$js("document.getElementById('dock').clientWidth")
    # The tools rail and the tray are beside the dock; the view is 65% of it
    expect_identical(br$js("document.getElementById('tools-rail').offsetWidth"), 36L)
    expect_lt(dock(), 1400 - 260 - 36)
    expect_equal(width("spatial"), round(0.65 * dock()), tolerance = 2)

    # The panels toggle hides every group but the view's, and the tray's
    # column (its rail stays), and gives the view its width back
    toggle <- "document.getElementById('btn-panels').click()"
    w0 <- width("spatial")
    br$js(toggle)
    expect_true(browser_wait(br, "!document.getElementById('tray').classList.contains('open')"))
    expect_true(browser_wait(br, "document.querySelector('[data-panel=spatial]').clientWidth === document.getElementById('dock').clientWidth"))
    expect_gt(width("spatial"), 1400 - 36 - 60)
    p <- v$panels()
    expect_identical(p$visible, p$id == "spatial")
    br$js(toggle)
    expect_true(browser_wait(br, sprintf("document.querySelector('[data-panel=spatial]').clientWidth === %d", w0)))
    expect_true(br$js("document.getElementById('tray').classList.contains('open')"))
    # Hidden, a click on the tray's rail brings the tray back with that
    # control; the toggle then shows the rest at their widths
    br$js(toggle)
    expect_true(browser_wait(br, "!document.getElementById('tray').classList.contains('open')"))
    br$js("document.querySelector('.tray-rail [data-tray=layers]').click()")
    expect_true(browser_wait(br, "document.getElementById('tray').classList.contains('open') && !!document.querySelector('[data-panel=layers]')"))
    br$js(toggle)
    expect_true(browser_wait(br, sprintf("document.querySelector('[data-panel=spatial]').clientWidth === %d", w0)))

    # Closed, its Deck gives back its WebGL context and its tiles go; R gets
    # an error for what needs a view, and the selection still works
    v$set_view(x = 10, y = -20, zoom = 3)
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"zoom":3', priv$config_json %||% "", fixed = TRUE)))
    br$js("(window.__gl = window.__giottolens.spatial.deck.device.gl, true)")
    v$remove_panel("spatial")
    expect_true(browser_wait(br, "window.__giottolens.spatial === null && window.__gl.isContextLost()"))
    expect_identical(br$js("window.__giottolens.state.cache.size"), 0L)
    expect_error(v$view_bounds(), "no spatial view")
    expect_error(v$set_view(zoom = 1), "no spatial view")
    expect_error(v$screenshot(), "no spatial view")
    v$set_selection(c("cell_001", "cell_002"))
    expect_true(browser_wait(br, "document.getElementById('sel-count').textContent.startsWith('2 ')"))

    # It stays closed after a reload, and a group's + brings it back where it
    # was looking
    browser_reload(br)
    expect_true(browser_wait(br, paste("!!document.querySelector('.r-status.connected')",
        "&& window.__giottolens.store.getState().closedPanels.includes('spatial')")))
    expect_false("spatial" %in% v$panels()$id)
    expect_null(br$js("window.__giottolens.spatial"))
    br$js("[...document.querySelectorAll('.dv-tab')].find(t => t.textContent.trim() === 'scatter').closest('.dv-groupview').querySelector('.dock-add').click()")
    br$js("[...document.querySelectorAll('.dock-menu.open button')].find(b => b.textContent === 'spatial').click()")
    expect_true(browser_wait(br, "window.__giottolens.spatial?.viewState?.zoom === 3"))
    expect_identical(unlist(br$js("window.__giottolens.spatial.viewState.target.slice(0, 2)")), c(10L, -20L))
    expect_true(browser_wait(br, tiles_loaded))
    expect_false("spatial" %in% unlist(br$js("window.__giottolens.store.getState().closedPanels")))

    # A layout saved before the view docked gets the view
    br$js("(() => { const g = window.__giottolens, L = structuredClone(g.store.getState().layout);
      const keep = n => {
        if (n.type !== 'leaf') return (n.data = n.data.filter(keep), true);
        n.data.views = n.data.views.filter(id => id !== 'spatial');
        if (n.data.activeView === 'spatial') n.data.activeView = n.data.views[0];
        return n.data.views.length > 0;
      };
      keep(L.grid.root); delete L.panels.spatial; g.actions.setLayout(L); })()")
    expect_true(browser_wait(br, "window.__giottolens.spatial?.viewState != null"))
    expect_identical(v$panels()$id[1:2], c("spatial", "scatter"))
    expect_no_browser_errors(br)
})

test_that("a group splits into an empty pane that lists what it can show", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 1400, height = 800)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, tiles_loaded))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    expect_true(pump_until(function() v$connected()))
    groups <- function() { p <- v$panels(); setNames(p$group, p$id) }
    n_groups <- function() br$js("document.querySelectorAll('.dv-groupview').length")
    empty <- "document.querySelector('.dv-groupview .dock-empty')"
    pick <- function(kind) br$js(sprintf(
        "[...%s.querySelectorAll('button')].find(b => b.textContent === '%s').click()", empty, kind))
    # By the tab: a panel's content is rendered outside its group's element
    split <- function(of, dir) br$js(sprintf(paste0(
        "[...document.querySelectorAll('.dv-tab')].find(t => t.textContent.trim() === '%s')",
        ".closest('.dv-groupview').querySelector('.dock-split[data-split=%s]').click()"), of, dir))
    n0 <- n_groups()
    g0 <- groups()

    # Split right of the spatial view: an empty pane with the "+" menu's
    # panels in it; one picked opens there
    split("spatial", "right")
    expect_true(browser_wait(br, sprintf("document.querySelectorAll('.dv-groupview').length === %d && !!%s", n0 + 1, empty)))
    expect_identical(groups(), g0)
    pick("density")
    expect_true(browser_wait(br, sprintf("!!document.querySelector('[data-panel=density]') && !%s", empty)))
    g <- groups()
    expect_false(g[["density"]] %in% g0)

    # Split down: the spatial view, open elsewhere, moves into the empty pane
    split("density", "below")
    expect_true(browser_wait(br, paste0("!!", empty)))
    pick("spatial")
    expect_true(browser_wait(br, sprintf("!%s", empty)))
    g <- groups()
    expect_false(g[["spatial"]] %in% c(g0, g[["density"]]))
    expect_identical(sum(v$panels()$id == "spatial"), 1L)
    expect_true(browser_wait(br, "window.__giottolens.spatial?.viewState != null"))

    # An empty pane survives a reload with the layout, and closes
    split("scatter", "below")
    expect_true(browser_wait(br, paste0("!!", empty)))
    n1 <- n_groups()
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"views":[]', priv$config_json %||% "", fixed = TRUE)))
    browser_reload(br)
    expect_true(browser_wait(br, paste0("!!document.querySelector('.r-status.connected') && !!", empty)))
    expect_identical(n_groups(), n1)
    br$js(sprintf("%s.querySelector('.dock-empty-close').click()", empty))
    expect_true(browser_wait(br, sprintf("document.querySelectorAll('.dv-groupview').length === %d && !%s", n1 - 1L, empty)))
    expect_no_browser_errors(br)
})

test_that("a module shows its controls and its view alone, and leaving puts both back", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$g, open = FALSE, images = "stain", image_files = c(hne = fx$rgb_file))
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 1200, height = 800)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.images?.size === 2"))
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    tray_show(br, "selection")
    shown <- function() unlist(br$js("[...document.querySelectorAll('.tray-section')].filter(s => s.style.display !== 'none').map(s => s.dataset.control)"))
    rail <- function() unlist(br$js("[...document.querySelectorAll('.tray-rail [data-tray]')].filter(b => b.style.display !== 'none').map(b => b.dataset.tray)"))
    visible <- function() { p <- v$panels(); p$id[p$visible & p$group != "tray"] }
    tray0 <- shown()
    expect_false("register" %in% rail())
    expect_gt(length(visible()), 1L)
    panes0 <- visible()

    # On: the register control alone, offered and shown; the spatial view alone
    v$set_module("registration")
    expect_true(browser_wait(br, "!!document.querySelector('.tray-body[data-panel=register]')?.offsetParent"))
    expect_identical(shown(), "register")
    expect_identical(rail(), "register")
    expect_true(br$js("!!document.querySelector('.tray-leave').offsetParent"))
    expect_true(browser_wait(br, "document.querySelector('[data-panel=tools] [data-act=modules]').classList.contains('active')"))
    expect_true(pump_until(function() identical(visible(), "spatial")))
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"module":"registration"', priv$config_json %||% "", fixed = TRUE)))

    # A reload comes back in the module
    browser_reload(br)
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected') && !!document.querySelector('.tray-body[data-panel=register]')?.offsetParent"))
    expect_true(pump_until(function() identical(visible(), "spatial")))

    # Left by the rail's button: the tray's controls and the panes as before
    br$js("document.querySelector('.tray-leave').click()")
    expect_true(browser_wait(br, "!document.querySelector('.tray-leave').offsetParent"))
    expect_identical(shown(), tray0)
    expect_false("register" %in% rail())
    expect_true(pump_until(function() setequal(visible(), panes0)))
    expect_true(pump_until(function() grepl('"module":null', priv$config_json %||% "", fixed = TRUE)))
    expect_no_browser_errors(br)
})
