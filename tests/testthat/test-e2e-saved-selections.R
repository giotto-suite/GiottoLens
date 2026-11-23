# The selection panel's saved selections and a volcano pick, in the browser

test_that("the selection panel saves selections, and a volcano pick colors the cells", {
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    q <- function(sel) sprintf("document.querySelector('[data-panel=selection] %s')", sel)

    # One saved from R shows in the saved selections
    v$save_selection("right", lens_cells(dv$d$right))
    expect_true(browser_wait(br, sprintf("!!%s", q(".rg-item[data-saved=right]"))))

    # The page saves the selection under the name typed
    v$set_selection(dv$d$left)
    expect_true(browser_wait(br, sprintf("!%s.disabled", q(".rg-save"))))
    br$js(sprintf("(() => { %s.value = 'left'; %s.click(); })()", q(".rg-name"), q(".rg-save")))
    expect_true(pump_until(function() setequal(v$selections()$name, c("left", "right"))))
    expect_identical(length(v$selections("left")), length(dv$d$left))
    # A click brings its rules back
    v$select(NULL)
    br$js(sprintf("%s.click()", q(".rg-item[data-saved=left]")))
    expect_true(pump_until(function() setequal(v$selection, dv$d$left)))

    # Compare left vs right from R, reading the normalized values
    suppressMessages(v$compare_selections("left", "right", values = "normalized"))
    expect_true(suppressMessages(pump_until(function() nrow(v$de_results()) == 1L, timeout = 60)))
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=de-1] canvas')"))

    # A gene picked in the volcano plot colors the cells by its item key
    key <- .item_key("expression", "rna", "g1", name = "normalized")
    br$js("(() => { const v = window.__giottolens.panel('de-1').view;
        return v.signal('pick_tuple', { unit: 'layer_0', fields: v.signal('pick_tuple_fields'),
            values: ['g1'] }).runAsync().then(() => true); })()")
    expect_true(browser_wait(br, sprintf("window.__giottolens.store.getState().colorBy === '%s'", key)))
    expect_true(browser_wait(br, "window.__giottolens.state.colorLegend?.type === 'continuous'"))

    # Genes share one scale: set for one, it stays for the next
    v$set_color_scale(style = "sequential", preset = "magma", limits = c(0, 2))
    v$color_by(.item_key("expression", "rna", "g2", name = "normalized"))
    lg <- br$js("(() => { const l = window.__giottolens.state.colorLegend;
        return { style: l.style, preset: l.scale.preset, lo: l.lo, hi: l.hi }; })()")
    expect_identical(lg, list(style = "sequential", preset = "magma", lo = 0L, hi = 2L))

    # Dragging the high handle on the bar to its middle moves the high end only
    # (the legend is the layers panel's; saving a selection showed the other)
    tray_show(br, "layers", "cells")
    pt <- br$js("(() => { const h = document.querySelector('.scale-handle[data-handle=hi]').getBoundingClientRect();
        const b = document.querySelector('.scale-bar').getBoundingClientRect();
        return [h.left + h.width / 2, h.top + h.height / 2, b.left + b.width / 2]; })()")
    mouse <- function(type, x, buttons) br$session$Input$dispatchMouseEvent(type = type, x = x,
        y = pt[[2]], button = "left", buttons = buttons, clickCount = 1L)
    mouse("mousePressed", pt[[1]], 1L)
    mouse("mouseMoved", (pt[[1]] + pt[[3]]) / 2, 1L)
    mouse("mouseMoved", pt[[3]], 1L)
    mouse("mouseReleased", pt[[3]], 0L)
    expect_true(browser_wait(br, "(() => { const l = window.__giottolens.state.colorLegend;
        return l.lo === 0 && Math.abs(l.hi - (l.min + l.max) / 2) < 0.02 * (l.max - l.min); })()", 10))
    sc <- v$state()$config$colorScales[["@expression"]]
    expect_equal(unlist(sc$limits)[1L], 0)
    expect_identical(br$errors(), character())
})
