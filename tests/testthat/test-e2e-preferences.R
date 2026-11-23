test_that("the tools bar's Preferences dialog shows and sets preferences in the page", {
    local_pref_file()
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() v$connected(), 30))
    # A gear in the tools bar opens it over the page; it is not a panel
    expect_false("preferences" %in% v$panels()$id)
    gear <- "document.querySelector('[data-panel=tools] [data-act=preferences]')"
    expect_true(browser_wait(br, sprintf("!!%s", gear), 30))
    br$js(sprintf("%s.click()", gear))
    expect_true(browser_wait(br, "!!document.querySelector('.start-overlay .pref-dialog .pref-panel')", 30))
    expect_true(br$js(sprintf("%s.classList.contains('active')", gear)))
    br$js("(() => { const d = document.querySelector('.pref-dialog details[data-section=\"Colors/Categories\"]');
        d.open = true; })()")
    br$js("(() => { const s = document.querySelector('[data-pref=cat_palette] select'); s.value = 'okabe_ito';
        s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function() identical(lens_preferences()$cat_palette, "okabe_ito"), 10))
    expect_true(browser_wait(br,
        "document.querySelector('[data-pref=cat_palette]').classList.contains('pref-set')", 10))
    # Escape closes it
    br$js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
    expect_true(browser_wait(br, "!document.querySelector('.start-overlay')", 10))
    expect_false(br$js(sprintf("%s.classList.contains('active')", gear)))
    lens_preferences(outline_color = "#ff8000")
    expect_true(browser_wait(br,
        "JSON.stringify(window.__giottolens.store.getState().outline.color) === '[255,128,0]'", 10))
    v$set_outline(color = "#00ff00")
    lens_preferences(outline_color = "#0000ff")
    pump_for(1)
    expect_identical(br$js("JSON.stringify(window.__giottolens.store.getState().outline.color)"),
        "[0,255,0]")

    # The selection color follows its preference until set in the viewer;
    # set_selection_color() with no color goes back to the preference
    sel <- function() unlist(v$state()$config$selectionColor)
    lens_preferences(selection_color = "#00e5ff")
    expect_true(browser_wait(br,
        "JSON.stringify(window.__giottolens.store.getState().selectionColor) === '[0,229,255]'", 10))
    v$set_selection_color("red")
    lens_preferences(selection_color = "#ffffff")
    pump_for(1)
    expect_identical(sel(), c(255L, 0L, 0L))
    v$set_selection_color()
    expect_identical(sel(), c(255L, 255L, 255L))
    expect_length(br$errors(), 0L)
})
