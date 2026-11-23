# Browser: the Data panel and the item picker

test_that("the Data panel lists the object and pulls the items queued", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    # The Data panel flies out from the tools rail
    br$js("document.querySelector('[data-panel=tools] [data-act=data]').click()")
    expect_true(browser_wait(br, "!!document.querySelector('.flyout-body[data-panel=data]')?.offsetParent"))
    q <- function(sel) sprintf("document.querySelector('[data-panel=data] %s')", sel)
    items <- sprintf("[...document.querySelectorAll('[data-panel=data] .data-item')].map(e => e.dataset.item)")
    expect_true(browser_wait(br, sprintf("%s.join() === 'array_row,array_col,half'", items)))

    # Queue from two sources, one with a type, and pull them together
    br$js(sprintf("%s.click()", q(".data-item[data-item=half]")))
    br$js(sprintf("%s.click()", q(".data-item[data-item=array_row]")))
    br$js(sprintf("(() => { const t = [...document.querySelectorAll('[data-panel=data] .data-type')][1]; t.value = 'categorical'; t.dispatchEvent(new Event('change')); })()"))
    br$js(sprintf("(() => { const s = %s; s.value = [...s.options].find(o => o.textContent.startsWith('expression')).value; s.dispatchEvent(new Event('change')); })()",
        q(".data-source")))
    expect_true(browser_wait(br, sprintf("%s.join() === 'g1,g2'", items)))
    br$js(sprintf("%s.click()", q(".data-item[data-item=g1]")))
    expect_identical(br$js(sprintf("%s.textContent", q(".data-pull"))), "pull 3")
    suppressMessages({
        br$js(sprintf("%s.click()", q(".data-pull")))
        expect_true(browser_wait(br, "['half', 'array_row', 'g1'].every(c => window.__giottolens.state.metaInfo?.has(c))"))
    })
    expect_identical(br$js("window.__giottolens.state.metaInfo.get('array_row').kind"), "categorical")
    expect_true(browser_wait(br, sprintf("%s.textContent.startsWith('pulled 3')", q(".data-status"))))
    expect_identical(br$js(sprintf("%s.textContent", q(".data-pull"))), "pull")
    # Pulled items are marked
    expect_true(browser_wait(br, sprintf("!!%s", q(".data-item.loaded[data-item=g1]"))))
    priv <- lens_priv(v)
    expect_setequal(priv$meta_names(), c("half", "array_row", "g1"))

    # A pull is a job: cancelled from the panel while a slow job holds the daemon
    priv$start_job("slow", function(g) { Sys.sleep(3); 1 })
    br$js(sprintf("%s.click()", q(".data-item[data-item=g2]")))
    br$js(sprintf("%s.click()", q(".data-pull")))
    expect_true(browser_wait(br, sprintf("%s.textContent === 'cancel' && !%s.disabled",
        q(".data-clear"), q(".data-clear"))))
    br$js(sprintf("%s.click()", q(".data-clear")))
    expect_true(browser_wait(br, sprintf("%s.textContent === 'cancelled'", q(".data-status"))))
    expect_false("g2" %in% priv$meta_names())
    expect_no_browser_errors(br)
})

test_that("the picker colors cells by an item without adding it to the metadata", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    tray_show(br, "layers", "cells")
    br$js("document.querySelector('[data-section=cells] .color-by-browse').click()")
    expect_true(browser_wait(br, "[...document.querySelectorAll('.picker .picker-source option')].some(o => o.textContent.startsWith('expression'))"))
    br$js("(() => { const s = document.querySelector('.picker .picker-source'); s.value = [...s.options].find(o => o.textContent.startsWith('expression')).value; s.dispatchEvent(new Event('change')); })()")
    expect_true(browser_wait(br, "!!document.querySelector('.picker .picker-item[data-item=g1]')"))
    key <- .item_key("expression", "rna", "g1", name = "raw")
    br$js("document.querySelector('.picker .picker-item[data-item=g1]').click()")
    expect_true(browser_wait(br, sprintf("window.__giottolens.store.getState().colorBy === '%s'", key)))
    expect_false(br$js("!!document.querySelector('.picker')"))
    expect_true(browser_wait(br, "window.__giottolens.state.colorLegend?.type === 'continuous'"))
    # Expression items share one scale, which the legend edits
    expect_identical(br$js("window.__giottolens.state.colorLegend.column"), "@expression")
    # It is in the menu's recent group, and not in the metadata
    expect_true(browser_wait(br, sprintf("[...document.querySelectorAll('[data-section=cells] .color-by optgroup option')].some(o => o.value === '%s')", key)))
    priv <- lens_priv(v)
    expect_false("g1" %in% priv$meta_names())
    expect_false(br$js("window.__giottolens.state.metaInfo?.has('g1') ?? false"))

    # From R, by a row of catalog(); an item the object lacks is refused
    tbl <- v$catalog()
    v$color_by(tbl[tbl$item == "g2", ])
    expect_identical(br$js("window.__giottolens.store.getState().colorBy"), tbl$key[tbl$item == "g2"])
    expect_error(v$color_by(.item_key("expression", "rna", "nope", name = "raw")), "has no 'nope'")
    v$color_by(NULL)
    expect_null(br$js("window.__giottolens.store.getState().colorBy"))
    expect_no_browser_errors(br)
})
