# A tiny GiottoDisk-backed dataset: 400 transcripts of 4 genes over a
# 100 x 100 extent, and 100 square cells. Built once per test run.
lens_fixture <- local({
    fx <- NULL
    function() {
        testthat::skip_if_not_installed("GiottoDisk")
        testthat::skip_if_not_installed("GiottoClass")
        if (!is.null(fx)) return(fx)
        suppressPackageStartupMessages(requireNamespace("GiottoDisk"))
        old_seed <- .Random.seed_or_null()
        set.seed(1)
        on.exit(.restore_seed(old_seed), add = TRUE)
        sw <- function(...) suppressMessages(suppressWarnings(...))

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
        fx <<- list(gpoints = gpoints, gpolygons = gpolygons, meta = meta)
        fx
    }
})

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

http_get <- function(url, headers = list(), timeout = 10) {
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

ws_client <- function(url, origin = NULL) {
    headers <- if (!is.null(origin)) list(Origin = origin)
    ws <- websocket::WebSocket$new(url, headers = headers, autoConnect = FALSE)
    state <- new.env()
    state$open <- FALSE; state$closed <- FALSE; state$msgs <- list()
    ws$onOpen(function(e) {
        state$open <- TRUE
        # A real tab announces itself once its handlers are registered
        ws$send('{"type":"ready","data":{"protocol":2}}')
    })
    ws$onClose(function(e) state$closed <- TRUE)
    ws$onMessage(function(e) state$msgs[[length(state$msgs) + 1L]] <-
        jsonlite::fromJSON(e$data, simplifyVector = FALSE))
    ws$connect()
    list(ws = ws, state = state)
}

ws_url <- function(viewer, token = NULL) {
    u <- sub("^http", "ws", paste0(viewer$url, "ws"))
    if (!is.null(token)) u <- sub("/lens/[^/]+/", paste0("/lens/", token, "/"), u)
    u
}

`%||%` <- function(x, y) if (is.null(x)) y else x
