# Browser: the viewer boots for each kind of object and transfer mode, and the power button stops it
# (polygons only: test-e2e-marks.R; a lasso reaching R: test-e2e-selection.R)

test_that("viewer boots offline with cross-filter on, and R selections reach the page", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)

    expect_true(browser_wait(br, tiles_loaded))
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br,
        "!!document.querySelector('.r-status.connected')"))
    # Cross-filter is on from the start, on both sides
    expect_identical(br$js("window.__giottolens.store.getState().combine"), "and")
    tray_show(br, "selection")
    expect_true(br$js("document.querySelector('[data-panel=selection] [data-act=and]').classList.contains('active')"))
    expect_identical(lens_priv(v)$combine, "and")

    # Transcripts on: tiles go through the Range handler
    br$js("document.querySelector('[data-panel=layers] [data-layer=tx] .show').click()")
    expect_true(browser_wait(br, tiles_loaded))

    v$set_selection(c("cell_001", "cell_002", "cell_003"))
    expect_true(browser_wait(br,
        "document.getElementById('sel-count').textContent.startsWith('3 ')"))

    v$push_metadata(fx$meta)
    expect_true(browser_wait(br,
        "document.querySelector('[data-section=cells] .color-by').options.length === 3"))
    dock_add(br, "histogram")
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=histogram] canvas')"))

    # Everything comes from this server: works offline, one DuckDB
    external <- br$js("performance.getEntriesByType('resource').map(e => e.name).filter(u => !u.startsWith(location.origin))")
    expect_length(external, 0L)

    expect_no_browser_errors(br)
})

test_that("a points-only viewer boots without errors", {
    fx <- lens_fixture()
    v  <- launch_lens(fx$gpoints, NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)

    expect_true(browser_wait(br, "[...(window.__giottolens?.state.cache.keys() ?? [])].some(k => k.startsWith('transcripts:'))"))
    expect_true(pump_until(function() v$connected()))
    # No cells, so no cells layer
    tray_show(br, "layers")
    expect_true(br$js("!!document.querySelector('[data-section=transcripts]')"))
    expect_false(br$js("!!document.querySelector('[data-section=cells]')"))
    expect_no_browser_errors(br)
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
        if (mode == "whole") expect_true(all(grepl("/lens/[^/]+/d/[^/]+/files/polygons/", urls)))
        else expect_true(all(grepl("/lens/[^/]+/d/[^/]+/data/polygons/", urls)))
        expect_no_browser_errors(br)
        br$close(); v$close()
    }
    expect_identical(counts$whole, counts$columns)
    expect_gt(counts$whole, 0)
})

test_that("an object in memory is written into a project and drawn from untiled stores", {
    fx <- lens_fixture()
    sw <- function(...) suppressMessages(suppressWarnings(...))
    g <- sw(GiottoClass::giotto())
    g <- sw(GiottoClass::setGiotto(g, GiottoClass::createGiottoPolygon(
        GiottoDisk::storeRead(fx$gpolygons@spatVector, output = "terra"), name = "cell",
        verbose = FALSE), verbose = FALSE))
    g <- sw(GiottoClass::setGiotto(g, GiottoClass::createGiottoPoints(
        GiottoDisk::storeRead(fx$gpoints@spatVector, output = "terra"), verbose = FALSE),
        verbose = FALSE))
    td <- tempfile("lensproj_")
    on.exit(unlink(td, recursive = TRUE), add = TRUE)
    v <- launch_lens(g, open = FALSE, project = td)
    on.exit(v$close(), add = TRUE)
    m <- jsonlite::fromJSON(rawToChar(http_get(lens_data_url(v, "session/manifest.json"))$content),
        simplifyVector = FALSE)
    expect_length(m$layers$cells$tiles, 1L)
    expect_length(m$layers$transcripts$tiles, 1L)

    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 100"))
    expect_true(pump_until(function() v$connected()))
    v$set_layer("tx", show = TRUE)
    v$set_view(x = 50, y = -50, zoom = 3)
    expect_true(browser_wait(br, "window.__giottolens.state.cache.has('polygons:1') && window.__giottolens.state.cache.has('transcripts:1')"))
    expect_no_browser_errors(br)
})

test_that("the power button stops the viewer, and a stopped viewer's page stops reconnecting", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    priv <- lens_priv(v)
    stop_btn <- "document.getElementById('btn-close')"
    expect_true(browser_wait(br, sprintf("!%s.disabled", stop_btn)))
    expect_true(pump_until(function() v$connected()))

    # One click only arms it
    br$js(sprintf("%s.click()", stop_btn))
    expect_true(br$js(sprintf("%s.classList.contains('armed')", stop_btn)))
    later::run_now(0.3)
    expect_false(is.null(priv$server))
    expect_message({
        br$js(sprintf("%s.click()", stop_btn))
        expect_true(pump_until(function() is.null(priv$server)))
    }, "stopped from the viewer")
    expect_true(browser_wait(br, "document.getElementById('r-status').classList.contains('closed')"))
    expect_true(br$js(sprintf("%s.disabled", stop_btn)))
    expect_match(br$js("document.getElementById('status').textContent"), "viewer stopped")
    expect_no_browser_errors(br)

    # Closed from R, the same
    v2 <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v2$close(), add = TRUE)
    br2 <- lens_browser(v2$url)
    on.exit(br2$close(), add = TRUE)
    expect_true(browser_wait(br2, sprintf("!%s.disabled", stop_btn)))
    expect_true(pump_until(function() v2$connected()))
    suppressMessages(v2$close())
    expect_true(browser_wait(br2, "document.getElementById('r-status').classList.contains('closed')"))
    expect_no_browser_errors(br2)
})
