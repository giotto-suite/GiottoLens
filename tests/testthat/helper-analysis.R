# A small object for analysis tests: 600 cells on a grid in three bands, each
# band a cell type with its own ten marker genes, 60 genes in all, raw counts,
# in a project (GiottoDisk). Small enough for every Preprocessing step to run
# in seconds, with clusters the steps find.
lens_analysis_fixture <- local({
    fx <- NULL
    function() {
        testthat::skip_if_not_installed("GiottoClass")
        testthat::skip_if_not_installed("GiottoDisk")
        testthat::skip_if_not_installed("Giotto")
        if (!is.null(fx)) return(fx)
        sw <- function(...) suppressMessages(suppressWarnings(...))
        grid <- expand.grid(col = 0:29, row = 0:19)
        ids <- sprintf("c%03d", seq_len(nrow(grid)))
        type <- c("A", "B", "C")[1L + (grid$col %/% 10L)]
        genes <- sprintf("gene%02d", 1:60)
        set.seed(7)
        rate <- matrix(1, 60L, length(ids))
        for (k in 1:3) rate[(k - 1L) * 10L + 1:10, type == c("A", "B", "C")[k]] <- 12
        m <- matrix(stats::rpois(length(rate), rate), 60L, dimnames = list(genes, ids))
        xy <- data.frame(sdimx = grid$col * 10, sdimy = -grid$row * 10, cell_ID = ids)
        g <- sw(GiottoClass::giotto())
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createExprObj(
            Matrix::Matrix(m, sparse = TRUE), spat_unit = "cell", feat_type = "rna",
            name = "raw"), verbose = FALSE))
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createSpatLocsObj(
            xy, spat_unit = "cell", name = "raw", verbose = FALSE), verbose = FALSE))
        meta <- data.frame(cell_ID = ids, band = type)
        g <- sw(GiottoClass::setGiotto(g, GiottoClass::createCellMetaObj(
            meta, spat_unit = "cell", feat_type = "rna", verbose = FALSE), verbose = FALSE))
        fx <<- list(g = .fixture_project(g), mem = g, xy = xy, meta = meta,
            markers = list(A = genes[1:10], B = genes[11:20], C = genes[21:30]))
        fx
    }
})

# QC thresholds the fixture's 60 genes pass, and PCA over all of them (too few to be
# highly variable)
lens_analysis_params <- list(filter = list(min_det_feats_per_cell = 10, feat_det_in_min_cells = 10),
    pca = list(feats_to_use = "all", ncp = 10))

# A viewer of the analysis fixture, its private environment and its analysis
lens_analysis_viewer <- function(params = lens_analysis_params, ...) {
    fx <- lens_analysis_fixture()
    v <- suppressMessages(launch_lens(fx$g, feat_type = NULL, open = FALSE))
    a <- v$analysis(params = params, ...)
    list(v = v, a = a, fx = fx, priv = get("private", v$.__enclos_env__),
        done = function() suppressMessages(v$close()))
}

# A viewer and its analysis, for the analysis tests: `meta()` is the
# analysis's columns as a data.frame by cell (factors as text), `panels()` the
# specs pushed by id, `sent()` what a connected tab heard. With `start`, the
# Preprocessing tab runs.
lens_analysis_rig <- function(..., g = NULL, start = TRUE) {
    testthat::skip_on_cran()
    testthat::skip_if_not_installed("websocket")
    fx <- lens_analysis_fixture()
    v <- suppressMessages(launch_lens(g %||% fx$g, feat_type = NULL, open = FALSE))
    priv <- get("private", v$.__enclos_env__)
    cl <- ws_client(ws_url(v), load = priv$load_seq)
    pump_until(function() v$connected())
    a <- suppressMessages(v$analysis(...))
    if (start) a$run("preprocess")
    list(v = v, a = a, priv = priv, fx = fx,
        meta = function() {
            d <- data.frame(cell_ID = priv$cell_ids)
            for (cn in priv$owned$analysis) {
                x <- priv$meta_column(cn)
                d[[cn]] <- if (is.factor(x)) as.character(x) else x
            }
            d
        },
        panels = function() lapply(priv$pushed, `[[`, "spec"),
        sent = function() lapply(cl$state$msgs, function(m) list(type = m$type, data = m$data)),
        done = function() {
            try(cl$ws$close(), silent = TRUE)
            suppressMessages(v$close())
        })
}
