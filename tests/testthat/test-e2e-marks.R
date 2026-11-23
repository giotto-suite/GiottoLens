# Browser: cell marks and bins drawn as marks, set from R and from the page

test_that("bins without polygons draw as dots, then squares, and select like cells", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$push_metadata(fx$meta[, c("cell_ID", "half")])
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    ids <- "window.__giottolens.spatial.deck.props.layers.map(l => l.id)"
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
    cells <- local({ p <- lens_priv(v); arrow::read_parquet(file.path(p$session, p$cells_file)) })
    ring  <- rbind(c(40, -85), c(75, -85), c(75, -50), c(40, -50))
    br$js(sprintf("window.__giottolens.actions.setRule('spatial', {source:'spatial',kind:'polygon',space:'spatial',params:{rings:[%s]}})",
        jsonlite::toJSON(ring)))
    br$js("window.__giottolens.actions.setCombine('and')")
    expected <- cells$cell_ID[pip(ring, cells$x, cells$y)]
    expected <- intersect(expected, fx$meta$cell_ID[fx$meta$half == "left"])
    expect_true(pump_until(function() setequal(v$selection, expected)))
    expect_gt(length(expected), 0L)
    expect_no_browser_errors(br)
})

test_that("the cell mark is set from R, survives a reload, and resets", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    layer <- function() br$js("(() => { const l = window.__giottolens.spatial.deck.props.layers.find(l => l.id.startsWith('cell-')); return l && [l.id, l.props.getRadius ?? l.props.radius]; })()")
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    v$set_view(x = 60, y = -60, zoom = 4)
    expect_true(pump_until(function() identical(layer(), list("cell-squares", 1L))))

    # From R: fields merge onto the launch mark
    v$set_mark(shape = "circle", size = 3)
    expect_true(pump_until(function() identical(layer(), list("cell-circles", 1.5))))
    expect_identical(v$describe()$cells$mark, list(shape = "circle", size = 3, angle = 10))

    # Saved with the viewer's settings: back after a reload
    priv <- lens_priv(v)
    expect_true(pump_until(function() grepl('"cellMark":{"shape":"circle","size":3}',
        priv$config_json %||% "", fixed = TRUE)))
    browser_reload(br)
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
    expect_no_browser_errors(br)
})

test_that("a polygons-only viewer boots, and its segmented cells take a mark when it is turned on", {
    fx <- lens_fixture()
    v  <- launch_lens(NULL, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    ids <- "window.__giottolens.spatial.deck.props.layers.map(l => l.id)"
    expect_true(browser_wait(br, tiles_loaded))
    expect_true(pump_until(function() v$connected(), 20))
    # No transcripts, so no transcripts layer
    tray_show(br, "layers")
    expect_true(br$js("!!document.querySelector('[data-section=cells]')"))
    expect_false(br$js("!!document.querySelector('[data-section=transcripts]')"))
    # Below outline zoom: dots by default
    v$set_view(x = 50, y = -50, zoom = -3)
    expect_true(browser_wait(br, sprintf("%s.includes('cell-centroids')", ids)))
    expect_identical(v$describe()$cells$mark, NULL)
    v$set_mark(show = TRUE)
    expect_true(browser_wait(br, sprintf("%s.includes('cell-circles')", ids)))
    expect_identical(v$describe()$cells$mark$shape, "circle")
    expect_no_browser_errors(br)
})
