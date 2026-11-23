# Browser: R drives the viewer through its methods

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
    expect_identical(v$style_categories(colors = c(a = "#010203"), alpha = c(0.2, b = 1)),
        "leiden_clus")
    cs <- v$state()$config$categoryStyles$leiden_clus
    expect_identical(unlist(cs$a$color), 1:3)
    expect_equal(cs$a$alpha, 0.2)
    expect_equal(cs$b$alpha, 1)
    v$style_categories(show = c(a = FALSE))
    expect_false(v$state()$config$categoryStyles$leiden_clus$a$show)
    expect_error(v$style_categories(alpha = c(zz = 1)), "not categories of 'leiden_clus': zz")
    v$style_categories(reset = TRUE)
    expect_length(v$state()$config$categoryStyles$leiden_clus, 0L)
    v$style_categories(colors = c(a = "#010203"))
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .legend-color')?.value === '#010203'"))
    br$js("document.querySelector('[data-section=cells] .legend-actions [data-act=reset]').click()")
    expect_true(browser_wait(br,
        "Object.keys(window.__giottolens.store.getState().categoryStyles.leiden_clus ?? {}).length === 0"))
    # A column not loaded (over the prefetch budget) is styled from its kind and
    # levels, and loads again to be drawn
    br$js("window.__giottolens.state.meta.delete('leiden_clus'); true")
    expect_identical(v$style_categories(alpha = c(b = 0.5)), "leiden_clus")
    expect_equal(v$state()$config$categoryStyles$leiden_clus$b$alpha, 0.5)
    expect_true(browser_wait(br, "window.__giottolens.state.meta.has('leiden_clus')"))
    v$style_categories(reset = TRUE)
    expect_error(v$set_color_scale(), "is not continuous")
    expect_identical(v$set_color_scale("score", preset = "magma", reverse = TRUE), "score")
    sc <- v$state()$config$colorScales$score
    expect_identical(sc$preset, "magma")
    expect_true(sc$reverse)
    v$color_by("score")
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .scale-preset')?.value === 'magma'"))
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .cells-type')?.style.display === ''"))
    v$color_by("leiden_clus")
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .cells-type')?.style.display === 'none'"))
    v$set_color_scale("score", colors = c("black", "#ff0000", "white"))
    sc <- v$state()$config$colorScales$score
    expect_identical(sc$preset, "custom")
    expect_identical(lapply(sc$colors, unlist), list(c(0L, 0L, 0L), c(255L, 0L, 0L), c(255L, 255L, 255L)))
    expect_error(v$set_color_scale("score", preset = "nope"), "preset must be one of")
    v$set_color_scale("score", reset = TRUE)
    expect_null(v$state()$config$colorScales$score)
    v$set_color_scale("score", style = "sequential", midpoint = 2, limits = c(1, 5))
    sc <- v$state()$config$colorScales$score
    expect_identical(sc$style, "sequential")
    expect_equal(sc$midpoint, 2)
    expect_equal(unlist(sc$limits), c(1, 5))
    v$color_by("score")
    expect_true(browser_wait(br, "window.__giottolens.state.colorLegend?.lo === 1", 10))
    v$set_color_scale("score", midpoint = NA, limits = NA)
    sc <- v$state()$config$colorScales$score
    expect_null(sc$midpoint)
    expect_null(sc$limits)
    v$set_color_scale("score", reset = TRUE)
    v$color_by("leiden_clus")
    v$set_layer("tx", show = TRUE)
    v$show_genes(c("Actb", "Cd3e"))
    expect_identical(unlist(v$state()$config$outline$color), c(0L, 0L, 0L))
    v$set_outline(color = "#102030", width = 2.5)
    expect_identical(unlist(v$state()$config$outline$color), c(16L, 32L, 48L))
    expect_equal(v$state()$config$outline$width, 2.5)
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .outline-color')?.value === '#102030'"))
    v$set_outline(width = 1, alpha = 0.4)
    expect_identical(unlist(v$state()$config$outline$color), c(16L, 32L, 48L))
    expect_equal(v$state()$config$outline$alpha, 0.4)
    br$js("document.querySelector('[data-section=cells] .outline-reset').click()")
    expect_true(browser_wait(br,
        "window.__giottolens.store.getState().outline.alpha === 0.8"))
    expect_identical(unlist(v$state()$config$selectionColor), c(255L, 220L, 50L))
    v$set_selection_color("#00e5ff")
    expect_identical(unlist(v$state()$config$selectionColor), c(0L, 229L, 255L))
    v$set_selection_color()
    expect_identical(unlist(v$state()$config$selectionColor), c(255L, 220L, 50L))
    # Light panels, the spatial view still dark
    expect_null(v$state()$config$theme)
    v$set_theme("light")
    expect_identical(v$state()$config$theme, "light")
    expect_true(browser_wait(br, "document.documentElement.dataset.theme === 'light'"))
    expect_true(browser_wait(br, paste0(
        "getComputedStyle(window.__giottolens.spatial.root).backgroundColor === 'rgb(13, 17, 23)' && ",
        "getComputedStyle(document.body).backgroundColor === 'rgb(243, 244, 246)'")))
    v$set_theme()
    expect_null(v$state()$config$theme)
    expect_true(browser_wait(br, "document.documentElement.dataset.theme === undefined"))

    png <- v$screenshot()
    expect_true(file.exists(png))
    expect_identical(readBin(png, "raw", 4L), as.raw(c(0x89, 0x50, 0x4e, 0x47)))

    br$js("window.__giottolens.actions.clearSelection()")
    expect_true(pump_until(function() length(v$selection) == 0L))
    lg <- v$log()
    expect_true(all(c("color_by", "clear") %in% lg$action))

    expect_no_browser_errors(br)
})

test_that("a type change redraws a histogram of the column once it loads", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    suppressMessages(v$push_metadata(fx$meta))
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    dock_add(br, "histogram")
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=histogram] canvas')"))
    expect_identical(br$js("document.querySelector('[data-panel=histogram] select')?.value"), "score")
    # The column gets a new file and is not loaded for a moment; the selection
    # update that follows must not read it
    v$set_column_type("score", "categorical")
    expect_true(browser_wait(br, "window.__giottolens.state.meta.get('score')?.kind === 'categorical'"))
    v$set_column_type("score", "continuous")
    expect_true(browser_wait(br, "window.__giottolens.state.meta.get('score')?.kind === 'continuous'"))
    expect_no_browser_errors(br)
})
