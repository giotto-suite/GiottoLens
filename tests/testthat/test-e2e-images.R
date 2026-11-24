# Browser: images drawn, oriented, registered by landmarks and added from R

test_that("images draw under the cells in data coordinates, and R sets them", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    loaded <- paste0("(() => { const L = window.__giottolens?.spatial?.deck?.layerManager?.getLayers() ?? [];",
        " const im = L.filter(l => /^img-/.test(l.id) && !l.parent);",
        " return im.length === 1 && im.every(l => l.isLoaded); })()")
    expect_true(browser_wait(br, loaded))

    # Pyramid from the COG's overview IFDs; contrast from the smallest level
    img <- br$js("(() => { const i = window.__giottolens.state.images.get('stain');
        return { levels: i.levels.length, width: i.width }; })()")
    expect_identical(img, list(levels = 4L, width = 1200L))
    st <- v$state()$config$images$stain
    expect_true(st$show)
    # (GDAL's overviews resample with cubic overshoot at the quadrant's edge)
    expect_equal(unlist(st$contrast), c(100, 4000), tolerance = 0.1)

    v$set_layer("poly", show = FALSE)
    v$set_image("stain", color = "white", contrast = c(0, 4000))
    expect_identical(unlist(v$state()$config$images$stain$color), c(255L, 255L, 255L))
    expect_error(v$set_image("nope"), "must be one of the viewer's images: stain, he")
    pump_for(0.3)
    expect_true(browser_wait(br, loaded))

    # The bright quadrant is the image's first rows and columns: top left
    px <- function(x, y) br$js(sprintf(
        "window.__giottolens.spatial.deck.getViewports()[0].project([%f, %f])", x, y))
    shot <- png::readPNG(v$screenshot())
    at <- function(p) shot[round(p[[2L]]) + 1L, round(p[[1L]]) + 1L, 1L]
    expect_gt(at(px(25, -25)), 0.8)
    expect_lt(at(px(75, -75)), 0.2)
    expect_lt(at(px(75, -25)), 0.2)

    # The contrast thumbs cannot pass each other, by pointer or keyboard
    tray_show(br, "layers", "images")
    expect_true(browser_wait(br, "!!document.querySelector('[data-section=images] .range2')"))
    br$js("(() => { const [lo, hi] = document.querySelectorAll('[data-section=images] .range2 input');
        lo.value = 3000; lo.dispatchEvent(new Event('input'));
        hi.value = 1000; hi.dispatchEvent(new Event('input')); })()")
    ct <- unlist(v$state()$config$images$stain$contrast)
    expect_identical(ct, c(3000L, 3001L))

    # The RGB image is told apart by its TIFF tags: drawn in its own colours,
    # with no colour or contrast to set
    v$set_image("stain", show = FALSE)
    expect_false(v$describe()$images[["stain"]])
    v$set_image("he", show = TRUE)
    he <- v$state()$config$images$he
    expect_true(he$rgb)
    expect_null(he$contrast)
    expect_error(v$set_image("he", contrast = c(0, 10)), "RGB image; it has no colour or contrast")
    expect_true(br$js("document.querySelectorAll('[data-section=images] .img-item')[1].querySelector('.range2') === null"))
    pump_for(0.3)
    expect_true(browser_wait(br, loaded))
    shot <- png::readPNG(v$screenshot())
    tl <- shot[round(px(25, -25)[[2L]]) + 1L, round(px(25, -25)[[1L]]) + 1L, 1:3]
    br_ <- shot[round(px(75, -75)[[2L]]) + 1L, round(px(75, -75)[[1L]]) + 1L, 1:3]
    expect_gt(tl[1L], 0.8); expect_lt(tl[3L], 0.2)
    expect_gt(br_[3L], 0.8); expect_lt(br_[1L], 0.2)
    expect_no_browser_errors(br)
})

test_that("flipped and rotated images are drawn where GiottoClass places them", {
    fx <- lens_image_fixture()
    turned <- GiottoClass::spin(GiottoClass::flip(fx$g@images$stain, direction = "horizontal"),
        30, x0 = 10, y0 = 5)
    turned@name <- "turned"
    g <- suppressMessages(suppressWarnings(GiottoClass::setGiotto(fx$g, turned, verbose = FALSE)))
    v <- launch_lens(g, open = FALSE, images = "turned")
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    loaded <- paste0("(() => { const L = window.__giottolens?.spatial?.deck?.layerManager?.getLayers() ?? [];",
        " const im = L.filter(l => /^img-/.test(l.id) && !l.parent);",
        " return im.length === 1 && im.every(l => l.isLoaded); })()")
    expect_true(browser_wait(br, loaded))
    v$set_layer("poly", show = FALSE)
    v$set_image("turned", color = "white", contrast = c(0, 4000))
    v$set_view(bounds = as.vector(terra::ext(turned)))
    pump_for(0.3)
    expect_true(browser_wait(br, loaded))

    # Centres of the bright and a dark quadrant, moved as GiottoClass moves points
    at <- GiottoClass:::.affine_matrix(rbind(c(25, -25), c(75, -75)), turned@affine[])
    shot <- png::readPNG(v$screenshot())
    value <- function(xy) {
        p <- br$js(sprintf("window.__giottolens.spatial.deck.getViewports()[0].project([%f, %f])",
            xy[[1L]], xy[[2L]]))
        shot[round(p[[2L]]) + 1L, round(p[[1L]]) + 1L, 1L]
    }
    expect_gt(value(at[1L, ]), 0.8)
    expect_lt(value(at[2L, ]), 0.2)
    expect_no_browser_errors(br)
})

test_that("an image is registered by landmarks, saved, reloaded and added to the object", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$g, open = FALSE, images = "stain", image_files = c(hne = fx$rgb_file))
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.images?.size === 2"))
    expect_true(module_available(br, "registration"))
    tray_show(br, "register")
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=register] .reg-start')"))
    expect_true(pump_until(function() v$connected()))
    expect_true(browser_wait(br,
        "!!document.querySelector('.r-status.connected')"))

    # The image file has no place yet: drawn inside the data's extent
    t0 <- unlist(br$js("window.__giottolens.state.images.get('hne').transform"))
    expect_equal(t0[c(2L, 4L)], c(0, 0))
    expect_gt(t0[[1L]], 0)
    expect_lt(t0[[5L]], 0)

    # hne pixels are stain pixels halved; stain pixels are 1/12 data units
    hne_to_stain <- diag(c(2, 2, 1))
    stain <- diag(c(100 / 1200, -100 / 1200, 1))
    truth <- stain %*% hne_to_stain
    kp <- data.frame(alignmentX = c(0, 600, 0, 300), alignmentY = c(0, 0, 600, 300))
    kp$fixedX <- 2 * kp$alignmentX
    kp$fixedY <- 2 * kp$alignmentY
    v$register_image("hne", reference = "stain", keypoints = kp)
    reg <- v$registration
    expect_s3_class(reg, "lens_registration")
    expect_true(reg$fitted)
    expect_equal(registration_matrix(reg), truth, tolerance = 1e-9)
    expect_equal(registration_matrix(reg, "reference"), hne_to_stain, tolerance = 1e-9)
    expect_lt(reg$rmse, 1e-9)
    expect_identical(br$js("window.__giottolens.store.getState().mode"), "landmark")

    # The image has its own pane on the left; the main view takes the right half
    expect_true(browser_wait(br, paste0("window.__giottolens.spatial.root.classList.contains('registering')",
        " && window.__giottolens.spatial.regDeck?.getViewports()[0]?.width > 0")))
    widths <- br$js("[window.__giottolens.spatial.el.regCanvas.clientWidth, window.__giottolens.spatial.canvas.clientWidth]")
    expect_lt(abs(widths[[1]] - widths[[2]]), 3)
    expect_false(br$js("document.querySelector('[data-panel=register] .reg-flip-h').disabled"))
    expect_false(br$js("document.querySelector('[data-panel=register] .reg-link').disabled"))

    # Two clicks make a pair: on the image in its pane (pane coordinates are
    # pixels with y negated), then on the reference in the main view
    click <- function(deck, canvas, x, y) {
        off <- br$js(sprintf("(() => { const r = %s.getBoundingClientRect(); return [r.left, r.top]; })()", sprintf("({'reg-canvas': window.__giottolens.spatial.el.regCanvas, 'deck-canvas': window.__giottolens.spatial.canvas})['%s']", canvas)))
        p <- br$js(sprintf("window.__giottolens.spatial.%s.getViewports()[0].project([%f, %f])", deck, x, y))
        for (type in c("mousePressed", "mouseReleased"))
            br$session$Input$dispatchMouseEvent(type = type, x = off[[1]] + p[[1]],
                y = off[[2]] + p[[2]], button = "left", clickCount = 1L)
    }
    click("regDeck", "reg-canvas", 120, -180)
    expect_true(browser_wait(br, "window.__giottolens.store.getState().registration.landmarks.length === 5"))
    click("deck", "deck-canvas", 20.5, -30.5)
    pump_until(function() isTRUE(!is.na(v$registration$landmarks$fixed_x[5L])), 5)
    lm <- v$registration$landmarks
    expect_identical(nrow(lm), 5L)
    expect_equal(c(lm$fixed_x[5L], lm$fixed_y[5L]), c(20.5, -30.5), tolerance = 0.2)
    expect_equal(c(lm$moving_x[5L], lm$moving_y[5L]), c(120, 180), tolerance = 1)
    expect_gt(v$registration$rmse, 0)

    # As in the main view, the middle button and a drag with Space held pan the
    # image's pane, and place no point there or in the main view
    n_lm <- function() br$js("window.__giottolens.store.getState().registration.landmarks.length")
    pane_t <- function() unlist(br$js("window.__giottolens.spatial.regDeck.props.viewState.target"))[1:2]
    mid <- function(canvas) unlist(br$js(sprintf("(() => { const r = %s.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()", sprintf("({'reg-canvas': window.__giottolens.spatial.el.regCanvas, 'deck-canvas': window.__giottolens.spatial.canvas})['%s']", canvas))))
    mouse <- function(type, p, button = "left") br$session$Input$dispatchMouseEvent(type = type, x = p[1], y = p[2],
        button = button, buttons = if (type == "mouseReleased") 0L else if (button == "middle") 4L else 1L, clickCount = 1L)
    drag <- function(from, by, button) {
        mouse("mouseMoved", from); mouse("mousePressed", from, button)
        for (f in c(0.5, 1)) mouse("mouseMoved", from + by * f, button)
        mouse("mouseReleased", from + by, button)
    }
    key <- function(type) br$session$Input$dispatchKeyEvent(type = type, code = "Space", key = " ",
        windowsVirtualKeyCode = 32L)
    t0 <- pane_t()
    drag(mid("reg-canvas"), c(40, 20), "middle")
    expect_true(pump_until(function() sum(abs(pane_t() - t0)) > 0))
    t0 <- pane_t()
    key("keyDown")
    drag(mid("reg-canvas"), c(-30, 10), "left")
    expect_true(pump_until(function() sum(abs(pane_t() - t0)) > 0))
    for (canvas in c("reg-canvas", "deck-canvas")) { mouse("mousePressed", mid(canvas)); mouse("mouseReleased", mid(canvas)) }
    key("keyUp")
    pump_for(0.3)
    expect_identical(n_lm(), 5L)
    expect_identical(br$js("window.__giottolens.store.getState().mode"), "landmark")

    # Turning the image's pane changes where it is drawn there, not the fit
    fit <- v$registration$transform
    br$js("document.querySelector('[data-panel=register] .reg-rot-ccw').click()")
    expect_true(browser_wait(br, "window.__giottolens.store.getState().registration.orient[1] !== 0"))
    pump_for(0.3)
    expect_equal(v$registration$transform, fit)

    # Saved as Xenium Explorer CSVs; the matrix alone places the image again
    dir <- withr::local_tempdir()
    files <- write_registration(v$registration, dir)
    v$clear_registration()
    expect_null(v$registration)
    expect_identical(br$js("window.__giottolens.store.getState().registration"), NULL)
    v$register_image("hne", reference = "stain", alignment = files[["alignment"]], tool = FALSE)
    expect_false(v$registration$fitted)
    expect_equal(v$registration$transform[1:2, 1:2], truth[1:2, 1:2], tolerance = 0.01)
    v$register_image("hne", reference = "stain", keypoints = files[["keypoints"]], tool = FALSE)
    expect_true(v$registration$fitted)
    expect_identical(nrow(v$registration$landmarks), 5L)

    # Into the giotto object as a giottoAffineImage over the data
    g <- suppressMessages(suppressWarnings(v$add_registered_image(fx$g, name = "hne_registered")))
    img <- g@images$hne_registered
    expect_s4_class(img, "giottoAffineImage")
    expect_equal(unname(as.vector(terra::ext(img))), c(0, 100, -100, 0), tolerance = 0.5)
    expect_no_browser_errors(br)
})

test_that("the add image button adds a file R picks, ready to register", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 900, height = 700)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    expect_true(pump_until(function() v$connected()))
    expect_false(module_available(br, "registration"))
    tray_show(br, "layers", "images")
    expect_true(browser_wait(br, "document.querySelector('[data-section=images] .img-add-status')?.textContent === 'no images'"))
    pick_type <- function(br, type) {
        br$js("document.querySelector('[data-section=images] .img-add').click()")
        expect_identical(br$js("[...document.querySelectorAll('.lens-modal .img-type-tile .img-type-title')].map(e => e.textContent)"),
            list("10x Xenium image", "IF", "H&E"))
        br$js(sprintf("document.querySelector('.lens-modal .img-type-tile[data-type=%s]').click()", type))
        expect_false(br$js("!!document.querySelector('.lens-modal')"))
    }

    # Escape closes the type picker without asking R
    br$js("document.querySelector('[data-section=images] .img-add').click()")
    expect_true(br$js("!!document.querySelector('.lens-modal')"))
    br$js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))")
    expect_false(br$js("!!document.querySelector('.lens-modal')"))
    expect_false(br$js("document.querySelector('[data-section=images] .img-add').disabled"))

    # Cancelled: nothing added
    withr::local_options(GiottoLens.choose_file = function() NULL)
    pick_type(br, "if")
    expect_true(browser_wait(br, "!document.querySelector('[data-section=images] .img-add').disabled"))
    expect_length(v$describe()$images, 0L)

    withr::local_options(GiottoLens.choose_file = function() fx$rgb_file)
    pick_type(br, "if")
    nm <- sub("\\.tif$", "", basename(fx$rgb_file))
    expect_true(browser_wait(br, sprintf("window.__giottolens.state.images?.has('%s')", nm)))
    expect_true(browser_wait(br, sprintf("document.querySelector('[data-section=images] .img-add-status')?.textContent === 'added %s'", nm)))
    expect_true(module_available(br, "registration"))
    expect_true(isTRUE(v$state()$config$images[[nm]]$show))

    # A name already taken is reported in the panel and the log, not the console
    withr::local_options(GiottoLens.choose_file = function() fx$rgb_file)
    pick_type(br, "if")
    expect_no_warning(expect_true(browser_wait(br,
        "document.querySelector('[data-section=images] .img-add-status.img-add-error') !== null")))
    expect_match(utils::tail(v$log(1L)$detail, 1L), "image names must be unique")

    # From R, then the first registered against it
    v$add_image(fx$image_file, name = "stain")
    expect_true(browser_wait(br, "window.__giottolens.state.images?.has('stain')"))
    kp <- data.frame(alignmentX = c(0, 600, 0, 300), alignmentY = c(0, 0, 600, 300))
    kp$fixedX <- 2 * kp$alignmentX
    kp$fixedY <- 2 * kp$alignmentY
    v$register_image(nm, reference = "stain", keypoints = kp)
    reg <- v$registration
    expect_true(reg$fitted)
    expect_equal(registration_matrix(reg, "reference"), diag(c(2, 2, 1)), tolerance = 1e-9)
    expect_s4_class(v$registered_image(), "giottoAffineImage")

    # A 10x Xenium image is placed in microns by its experiment.xenium
    xen <- lens_xenium_fixture()
    withr::local_options(GiottoLens.choose_file = function() xen$file)
    pick_type(br, "xenium")
    expect_true(browser_wait(br, "window.__giottolens.state.images?.has('ch0000_dapi')"))
    ext <- br$js("window.__giottolens.state.images.get('ch0000_dapi').entry.extent")
    expect_equal(unlist(ext), c(xmin = 0, xmax = 40, ymin = -50, ymax = 0))

    # A reload opens the added images again
    added <- jsonlite::fromJSON(rawToChar(
        http_get(lens_data_url(v, "session/images_added.json"))$content), simplifyVector = FALSE)
    expect_identical(vapply(added, `[[`, "", "name"), c(nm, "stain", "ch0000_dapi"))
    browser_reload(br)
    ok <- browser_wait(br, "window.__giottolens?.state.images?.size === 3")
    if (!ok) message("images after reload: ",
        paste(unlist(tryCatch(br$js("[...(window.__giottolens?.state.images?.keys() ?? [])]"),
            error = function(e) conditionMessage(e))), collapse = ", "),
        "\nimages_added.json in the page: ", tryCatch(br$js(
            "fetch(window.__giottolens.dataUrl('session/images_added.json'), { cache: 'no-store' }).then(r => r.status + ' ' + r.statusText).catch(e => String(e))"),
            error = function(e) conditionMessage(e)),
        "\nbrowser errors: ", paste(br$errors(), collapse = " | "),
        "\nlog: ", paste(utils::capture.output(print(v$log(10))), collapse = "\n"))
    expect_true(ok)
})
