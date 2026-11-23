sw <- function(...) suppressMessages(suppressWarnings(...))

# The private environment of a viewer, and an ask as the page sends it
lens_priv <- function(v) get("private", v$.__enclos_env__)
lens_ask <- function(v, ...) lens_priv(v)$ask(list(...))

# A tiny GiottoDisk-backed dataset: 400 transcripts of 4 genes over a
# 100 x 100 extent, and 100 square cells. Built once per test run.
lens_fixture <- local({
    fx <- NULL
    function() {
        testthat::skip_if_not_installed("GiottoDisk")
        testthat::skip_if_not_installed("GiottoClass")
        if (!is.null(fx)) return(fx)
        fx <<- .fixture_layers()
        fx
    }
})

# The fixture's layers, written as tile stores; each call writes new ones
.fixture_layers <- function() {
    suppressPackageStartupMessages(requireNamespace("GiottoDisk"))
    old_seed <- .Random.seed_or_null()
    set.seed(1)
    on.exit(.restore_seed(old_seed), add = TRUE)

    n   <- 400L
    pts <- terra::vect(data.frame(
        x = stats::runif(n, 0, 100), y = stats::runif(n, -100, 0),
        feat_ID = sample(c("Actb", "Cd3e", "Ms4a1", "Epcam"), n, TRUE)
    ), geom = c("x", "y"))
    pstore <- sw(GiottoDisk::storeWrite(GiottoDisk::parquetGeomStore(), pts))
    ptile  <- sw(GiottoDisk::storeWrite(GiottoDisk::parquetGeomTileStore(), pstore,
        threshold = 100L))
    gpoints <- sw(GiottoClass::createGiottoPoints(ptile, verbose = FALSE))

    sq  <- function(cx, cy, r = 3) sprintf(
        "POLYGON((%f %f,%f %f,%f %f,%f %f,%f %f))",
        cx - r, cy - r, cx + r, cy - r, cx + r, cy + r, cx - r, cy + r, cx - r, cy - r)
    cen <- expand.grid(x = seq(5, 95, 10), y = seq(-95, -5, 10))
    pv  <- terra::vect(sq(cen$x, cen$y))
    pv$poly_ID <- sprintf("cell_%03d", seq_len(nrow(cen)))
    gpolygons <- sw(GiottoClass::createGiottoPolygon(pv, name = "cell", verbose = FALSE))
    pgs <- sw(GiottoDisk::storeWrite(GiottoDisk::parquetGeomStore(), gpolygons[]))
    gpolygons@spatVector <- sw(GiottoDisk::storeWrite(
        GiottoDisk::parquetGeomTileStore(), pgs, threshold = 30L))

    meta <- data.frame(
        cell_ID = pv$poly_ID,
        leiden.clus = rep(c("a", "b"), length.out = nrow(cen)),
        score = seq_len(nrow(cen)) / 10
    )
    list(gpoints = gpoints, gpolygons = gpolygons, meta = meta)
}

# Giotto object `g` saved as snapshot "fixture" in a new project, as an object
# loaded from a project is
.fixture_project <- function(g) {
    src <- sw(GiottoDisk::gDirSource(tempfile("lensproj_")))
    g <- sw(GiottoDisk::sourceWrite(src, g))
    sw(GiottoDisk::snapshotSave(src, g, name = "fixture", verbose = FALSE))
}

# The fixture as a giotto object with two images over the same 100 x 100
# extent: "stain", a 1200 x 1200 16-bit COG (three overview levels) bright in
# its top-left quadrant, so the drawn orientation can be checked; and "he", a
# 600 x 600 RGB COG, JPEG-compressed (YCbCr, as H&E files are), red in its
# top-left quadrant and blue elsewhere.
lens_image_fixture <- local({
    fx <- NULL
    function() {
        base <- lens_fixture()
        if (!is.null(fx)) return(fx)
        m <- matrix(100L, 1200L, 1200L)
        m[1:600, 1:600] <- 4000L
        file <- tempfile("stain", fileext = ".tif")
        terra::writeRaster(terra::rast(m), file, filetype = "COG", datatype = "INT2U",
            gdal = c("BLOCKSIZE=256", "COMPRESS=DEFLATE"))
        img <- GiottoClass::createGiottoLargeImage(file, name = "stain", verbose = FALSE)
        terra::ext(img) <- c(0, 100, -100, 0)

        red <- matrix(0L, 600L, 600L)
        red[1:300, 1:300] <- 255L
        he <- terra::rast(list(terra::rast(red), terra::rast(0L * red), terra::rast(255L - red)))
        rgb_file <- tempfile("he", fileext = ".tif")
        terra::writeRaster(he, rgb_file, filetype = "COG", datatype = "INT1U",
            gdal = c("BLOCKSIZE=256", "COMPRESS=JPEG"))
        rgb_img <- GiottoClass::createGiottoLargeImage(rgb_file, name = "he", verbose = FALSE)
        terra::ext(rgb_img) <- c(0, 100, -100, 0)
        # Its own stores: saving into the project moves them into its vault
        own <- .fixture_layers()
        g <- sw(GiottoClass::giotto())
        g <- sw(GiottoClass::setGiotto(g, own$gpolygons, verbose = FALSE))
        g <- sw(GiottoClass::setGiotto(g, own$gpoints, verbose = FALSE))
        g <- sw(GiottoClass::setGiotto(g, img, verbose = FALSE))
        g <- sw(GiottoClass::setGiotto(g, rgb_img, verbose = FALSE))
        g <- .fixture_project(g)
        fx <<- c(base, list(g = g, image_file = file, rgb_file = rgb_file))
        fx
    }
})

# Bins without polygons: a giotto object whose "bin" spatial unit has only
# spatial locations, 900 bins on a 30 x 30 grid of spacing 2 turned by 10
# degrees, with array_row and array_col in the cell metadata as VisiumHD
# bins have. `g` is in a project; `mem`, the same object in memory.
lens_bins_fixture <- local({
    fx <- NULL
    function() {
        testthat::skip_if_not_installed("GiottoClass")
        testthat::skip_if_not_installed("GiottoDisk")
        if (!is.null(fx)) return(fx)
        grid <- expand.grid(col = 0:29, row = 0:29)
        a  <- 10 * pi / 180
        xy <- data.frame(
            sdimx = 2 * (grid$col * cos(a) - grid$row * sin(a)) + 50,
            sdimy = 2 * (grid$col * sin(a) + grid$row * cos(a)) - 80,
            cell_ID = sprintf("bin_%02d_%02d", grid$row, grid$col)
        )
        m <- matrix(rep(c(1, 0, 0, 1), length.out = 2L * nrow(xy)), 2L,
            dimnames = list(c("g1", "g2"), xy$cell_ID))
        g <- sw(GiottoClass::giotto())
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createExprObj(m, spat_unit = "bin",
            feat_type = "rna", name = "raw"), verbose = FALSE))
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createSpatLocsObj(
            xy, spat_unit = "bin", name = "raw", verbose = FALSE), verbose = FALSE))
        meta <- data.frame(cell_ID = xy$cell_ID, array_row = grid$row, array_col = grid$col,
            half = ifelse(grid$col < 15, "left", "right"))
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createCellMetaObj(
            meta, spat_unit = "bin", feat_type = "rna", verbose = FALSE), verbose = FALSE))
        fx <<- list(g = .fixture_project(g), mem = g, xy = xy, meta = meta)
        fx
    }
})

# A Xenium output folder with what Giotto's Xenium reader needs to load a
# morphology image: experiment.xenium (pixel size 0.5), an expression file,
# and morphology_focus/ch0000_dapi.tif of 80 x 100 pixels
lens_xenium_fixture <- local({
    fx <- NULL
    function() {
        testthat::skip_if_not_installed("Giotto")
        if (!is.null(fx)) return(fx)
        dir <- tempfile("xenium")
        dir.create(file.path(dir, "morphology_focus"), recursive = TRUE)
        writeLines('{"pixel_size": 0.5}', file.path(dir, "experiment.xenium"))
        file.create(file.path(dir, "cell_feature_matrix.h5"))
        file <- file.path(dir, "morphology_focus", "ch0000_dapi.tif")
        terra::writeRaster(terra::rast(matrix(100L, 100L, 80L)), file, filetype = "COG",
            datatype = "INT2U", gdal = c("BLOCKSIZE=256"))
        fx <<- list(dir = dir, file = file)
        fx
    }
})

# The routes a viewer's app reads (see .lens_app())
lens_routes <- function(mounts = list(), images = list(), secret = "sec") {
    e <- new.env(parent = emptyenv())
    e$secret <- secret
    e$mounts <- lapply(mounts, normalizePath, mustWork = TRUE)
    e$images <- lapply(images, normalizePath, mustWork = TRUE)
    e
}

.Random.seed_or_null <- function() {
    if (exists(".Random.seed", globalenv())) get(".Random.seed", globalenv())
}
.restore_seed <- function(seed) {
    if (is.null(seed)) rm(list = ".Random.seed", envir = globalenv())
    else assign(".Random.seed", seed, envir = globalenv())
}

# ── Event-loop helpers ───────────────────────────────────────────────────────
# The data handler and WebSocket callbacks run on this R thread through
# `later`, so clients in the same process must pump the loop while waiting.

pump_until <- function(cond, timeout = 10) {
    t0 <- Sys.time()
    while (!isTRUE(cond())) {
        if (as.numeric(Sys.time() - t0, units = "secs") > timeout) return(FALSE)
        later::run_now(0.02)
    }
    TRUE
}

# Run the event loop for `secs`, for what should (or should not) arrive
pump_for <- function(secs) invisible(pump_until(function() FALSE, secs))

http_get <- function(url, headers = list(), timeout = 10) {
    testthat::skip_if_not_installed("curl")
    res <- NULL
    h <- curl::new_handle()
    if (length(headers)) curl::handle_setheaders(h, .list = headers)
    pool <- curl::new_pool()
    curl::curl_fetch_multi(url, done = function(r) res <<- r,
        fail = function(e) res <<- list(error = e), handle = h, pool = pool)
    ok <- pump_until(function() {
        curl::multi_run(timeout = 0, poll = TRUE, pool = pool)
        !is.null(res)
    }, timeout)
    if (!ok) stop("http_get timed out: ", url)
    if (!is.null(res$error)) stop(res$error)
    res$headers_list <- curl::parse_headers_list(res$headers)
    res
}

# The viewer on the port of `url`
lens_viewer_at <- function(url) {
    port <- regmatches(url, regexec("^[a-z]+://[^/:]+:([0-9]+)/", url))[[1L]][2L]
    .lens_registry[[port]]
}

# A window as the page behaves (adr/0028): `hello` on open, then `ready` once
# R gives it the viewer. `state$msgs` holds what R sends after that;
# `state$grant`, `state$wait` and `state$released` the handshake.
# `allow`: let it in with viewer$allow(), as a window launch_lens() opened;
#   FALSE for a window that asks and waits.
# `key`: the key of an earlier grant, as a reload sends it.
# `load`: the load the page says it shows (the manifest's), or NULL to say
#   nothing, as a page from before set_object() existed
ws_client <- function(url, origin = NULL, load = NULL, allow = TRUE, key = NULL) {
    testthat::skip_if_not_installed("websocket")
    if (allow) {
        viewer <- lens_viewer_at(sub("^ws", "http", url))
        if (!is.null(viewer)) suppressMessages(viewer$allow())
    }
    headers <- if (!is.null(origin)) list(Origin = origin)
    ws <- websocket::WebSocket$new(url, headers = headers, autoConnect = FALSE)
    state <- new.env()
    state$open <- FALSE; state$closed <- FALSE; state$msgs <- list()
    ws$onOpen(function(e) {
        state$open <- TRUE
        ws$send(jsonlite::toJSON(list(type = "hello", data = list(protocol = .lens_protocol,
            key = key)), auto_unbox = TRUE, null = "null"))
    })
    ws$onClose(function(e) state$closed <- TRUE)
    ws$onMessage(function(e) {
        m <- jsonlite::fromJSON(e$data, simplifyVector = FALSE)
        if (m$type == "grant") {
            state$grant <- m$data
            # A real page announces itself once its handlers are registered
            ws$send(jsonlite::toJSON(list(type = "ready", data = c(list(protocol = .lens_protocol),
                if (!is.null(load)) list(load = load))), auto_unbox = TRUE))
        } else if (m$type == "wait") state$wait <- m$data
        else if (m$type == "released") state$released <- TRUE
        else state$msgs[[length(state$msgs) + 1L]] <- m
    })
    ws$connect()
    list(ws = ws, state = state)
}

# What window `cl` heard of `type`; what it says to R; an ask it sends and
# the answer R gives
ws_msgs <- function(cl, type) Filter(function(m) identical(m$type, type), cl$state$msgs)
ws_say <- function(cl, type, data = NULL)
    cl$ws$send(jsonlite::toJSON(list(type = type, data = data), auto_unbox = TRUE, null = "null"))
ws_ask <- function(cl, id, ...)
    cl$ws$send(jsonlite::toJSON(list(type = "ask", id = id, data = list(...)), auto_unbox = TRUE))
ws_answer <- function(cl, id, timeout = 10) {
    hit <- NULL
    pump_until(function() {
        for (m in ws_msgs(cl, "answer")) if (identical(m$data$id, id)) hit <<- m$data
        !is.null(hit)
    }, timeout)
    hit
}

# The URL of data path `rel` of `viewer`, under its current data secret
lens_data_url <- function(viewer, rel = "") {
    paste0(viewer$url, "d/", get("private", viewer$.__enclos_env__)$routes$secret, "/", rel)
}

ws_url <- function(viewer, token = NULL) {
    u <- sub("^http", "ws", paste0(viewer$url, "ws"))
    if (!is.null(token)) u <- sub("/lens/[^/]+/", paste0("/lens/", token, "/"), u)
    u
}

`%||%` <- function(x, y) if (is.null(x)) y else x

# Many tests launch from the fixture's layers on purpose; the deprecation is
# tested on its own (test-launch.R)
.lens_warned$layers <- TRUE

# Recent projects go to a file of the test run, not the user's data directory
options(GiottoLens.recent_projects = tempfile("recent_", fileext = ".json"))
