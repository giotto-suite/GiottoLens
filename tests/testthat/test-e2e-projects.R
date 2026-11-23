# Browser: set_object(), the start page, and saving and opening a project

test_that("set_object() reloads the page onto another object and back, each from a clean slate", {
    fx <- lens_image_fixture()
    bx <- lens_bins_fixture()
    v  <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "document.body.classList.contains('empty') && !!document.querySelector('.start')"))
    expect_true(pump_until(function() v$connected()))

    v$set_object(fx$g, images = FALSE)
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 100"))
    expect_false(br$js("document.body.classList.contains('empty')"))
    expect_true(pump_until(function() v$connected()))
    v$show_genes(c("Actb", "Cd3e"))
    v$set_view(x = 20, y = -30, zoom = 3)
    saved <- function() if (!is.null(priv$config_json)) jsonlite::fromJSON(priv$config_json)$state
    expect_true(pump_until(function() identical(saved()$view$zoom, 3L) || identical(saved()$view$zoom, 3)))
    expect_identical(sort(saved()$genes), c("Actb", "Cd3e"))

    v$set_object(bx$g, spat_unit = "bin", feat_type = NULL)
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 900"))
    expect_true(br$js("window.__giottolens.state.manifest.layers.transcripts === undefined"))
    expect_identical(br$js("window.__giottolens.store.getState().genes.length"), 0L)

    # Back: nothing of before is kept, so the camera is fitted again
    v$set_object(fx$g, images = FALSE)
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 100"))
    expect_identical(br$js("window.__giottolens.store.getState().genes.length"), 0L)
    expect_false(isTRUE(br$js("window.__giottolens.spatial.viewState.zoom === 3")))

    # A reload of the same object keeps its camera (the config R holds)
    expect_true(pump_until(function() v$connected()))
    v$set_view(x = 20, y = -30, zoom = 3)
    expect_true(pump_until(function() identical(as.numeric(saved()$view$zoom), 3)))
    br$session$Page$reload()
    expect_true(browser_wait(br, "window.__giottolens?.spatial?.viewState?.zoom === 3"))
    vs <- br$js("window.__giottolens.spatial.viewState.target")
    expect_equal(unlist(vs)[1:2], c(20, -30))
    expect_no_browser_errors(br)
})

test_that("the start page opens a project's snapshot, and asks before dropping work", {
    bx <- lens_bins_fixture()
    proj <- normalizePath(bx$g@source@path)
    v <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    row_open <- function(name) sprintf(paste0("(() => { const r = [...document.querySelectorAll('.start-row')]",
        ".find(r => r.querySelector('.start-name')?.firstChild?.textContent === '%s');",
        " r?.querySelector('.start-actions .start-btn')?.click(); return !!r; })()"), name)

    # The path box
    expect_true(browser_wait(br, "!!document.querySelector('.start-input')"))
    br$js(sprintf("(() => { const i = document.querySelector('.start-input'); i.value = %s;
        i.form.requestSubmit(); return true; })()", jsonlite::toJSON(proj, auto_unbox = TRUE)))
    expect_true(browser_wait(br, row_open("fixture")))
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 900"))
    expect_identical(normalizePath(lens_priv(v)$project@path), proj)

    # With an annotation, the project button's dialog asks first
    expect_true(pump_until(function() v$connected()))
    v$push_polygons("POLYGON((40 -70,60 -70,60 -50,40 -50,40 -70))")
    expect_true(pump_until(function() length(v$annotations) == 1L))
    br$js("document.querySelector('[data-panel=tools] [data-act=project]').click()")
    expect_true(browser_wait(br, row_open("fixture")))
    expect_true(browser_wait(br, "!!document.querySelector('.start-confirm')"))
    expect_length(v$annotations, 1L)
    br$js("document.querySelector('.start-confirm .danger').click()")
    expect_true(pump_until(function() !length(v$annotations)))
    expect_true(browser_wait(br, paste0("window.__giottolens?.state?.cells?.n === 900 && ",
        "!document.querySelector('.start-overlay')")))
    expect_no_browser_errors(br)
})

test_that("the page saves the work and opens the save from the start page", {
    bx <- lens_bins_fixture()
    td <- tempfile("lensproj_")
    on.exit(unlink(td, recursive = TRUE), add = TRUE)
    v <- suppressMessages(launch_lens(bx$mem, spat_unit = "bin", feat_type = NULL, open = FALSE,
        project = td))
    on.exit(v$close(discard = TRUE), add = TRUE)
    ids <- lens_priv(v)$cell_ids
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state?.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))

    # Metadata is read by the page from the working bundle (work/)
    suppressMessages(v$push_metadata(data.frame(cell_ID = ids,
        half = ifelse(seq_along(ids) <= 450L, "left", "right"))))
    v$color_by("half")
    expect_true(browser_wait(br, "window.__giottolens.state.meta?.has?.('half')"))
    v$save_selection("top", lens_cells(ids[1:20]))
    v$push_polygons("POLYGON((40 -70,60 -70,60 -50,40 -50,40 -70))", names = "kept")
    expect_true(pump_until(function() identical(names(v$annotations), "kept")))

    # The tools bar's save button
    br$js("document.querySelector('[data-panel=tools] [data-act=save]').click()")
    br$js("(() => { const f = document.querySelector('.save-panel');
        f.querySelector('.save-name').value = 'first';
        f.querySelector('.save-desc').value = 'from the page';
        f.requestSubmit(); return true; })()")
    expect_true(pump_until(function() nrow(v$saves()) == 1L))
    expect_identical(v$saves()$description, "from the page")
    expect_true(browser_wait(br, "document.querySelector('.save-status').textContent.startsWith('saved first.')"))

    # More work, then the save opened from the project dialog, after asking
    v$save_selection("bottom", lens_cells(ids[880:900]))
    v$push_polygons("POLYGON((0 -100,10 -100,10 -90,0 -90,0 -100))", names = "dropped")
    br$js("document.querySelector('[data-panel=tools] [data-act=project]').click()")
    open_save <- paste0("(() => { const r = [...document.querySelectorAll('.start-row')]",
        ".find(r => r.querySelector('.start-name')?.firstChild?.textContent === 'first');",
        " r?.querySelector('.start-actions .start-btn')?.click(); return !!r; })()")
    expect_true(browser_wait(br, open_save))
    expect_true(browser_wait(br, "!!document.querySelector('.start-confirm')"))
    br$js("document.querySelector('.start-confirm .danger').click()")
    expect_true(pump_until(function() identical(v$selections()$name, "top")))
    expect_true(browser_wait(br, paste0("window.__giottolens?.state?.cells?.n === 900 && ",
        "!document.querySelector('.start-overlay') && window.__giottolens.state.metaInfo?.has?.('half')")))
    # The saved annotation is back on the reloaded page, and stays in R
    expect_true(browser_wait(br,
        "window.__giottolens.store.getState().annotations.map(a => a.name).join() === 'kept'"))
    pump_for(0.5)
    expect_identical(names(v$annotations), "kept")

    # Deleted from the project dialog, after asking
    br$js("document.querySelector('[data-panel=tools] [data-act=project]').click()")
    delete_save <- paste0("(() => { const r = [...document.querySelectorAll('.start-row')]",
        ".find(r => r.querySelector('.start-name')?.firstChild?.textContent === 'first');",
        " r?.querySelector('.start-actions .start-btn.danger')?.click(); return !!r; })()")
    expect_true(browser_wait(br, delete_save))
    expect_true(browser_wait(br, "document.querySelector('.start-confirm .danger')?.textContent === 'Delete'"))
    expect_identical(nrow(v$saves()), 1L)
    br$js("document.querySelector('.start-confirm .danger').click()")
    expect_true(pump_until(function() nrow(v$saves()) == 0L))
    expect_true(browser_wait(br, paste0("!!document.querySelector('.start-row') && ",
        "!document.querySelector('.start-row .start-btn.danger')")))
    expect_no_browser_errors(br)
})
