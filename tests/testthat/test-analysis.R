test_that("step schema defaults are choices and the tree is ordered", {
    steps <- .analysis_steps()
    seen <- character()
    for (s in names(steps)) {
        input <- steps[[s]]$input
        if (!is.null(input)) expect_true(input %in% seen, info = s)
        seen <- c(seen, s)
        for (p in steps[[s]]$params) {
            if (p$type == "choice") {
                keys <- vapply(p$choices, `[[`, "", "value")
                expect_false(anyDuplicated(keys) > 0, info = paste(s, p$id))
                expect_true(p$default %in% keys, info = paste(s, p$id))
            } else if (p$type %in% c("column", "text")) {
                expect_identical(.param_key(p, p$default), p$default)
            } else {
                expect_identical(.param_key(p, p$default), p$default, info = paste(s, p$id))
                expect_lt(p$slider$min, p$slider$max)
            }
        }
    }
})

test_that("catalog entries are complete and their steps form trees", {
    cat <- .analysis_catalog()
    expect_identical(names(cat)[[1L]], "preprocess")
    expect_true(cat$preprocess$auto)
    ids <- unlist(lapply(cat, function(e) names(e$steps)), use.names = FALSE)
    expect_false(anyDuplicated(ids) > 0, info = paste(ids[duplicated(ids)], collapse = ", "))
    for (k in names(cat)) {
        e <- cat[[k]]
        expect_identical(e$id, k)
        expect_match(k, "^[a-z][a-z0-9_]*$")
        for (f in c("label", "brief", "description"))
            expect_true(is.character(e[[f]]) && length(e[[f]]) == 1L && nzchar(e[[f]]),
                info = paste(k, f))
        expect_true(length(e$inputs) > 0L && length(e$outputs) > 0L, info = k)
        if (k != "preprocess") expect_false(isTRUE(e$auto), info = k)
        seen <- character()
        for (s in names(e$steps)) {
            st <- e$steps[[s]]
            expect_true(is.function(st$run) && is.function(st$result), info = s)
            expect_true(is.character(st$label) && nzchar(st$label), info = s)
            if (!is.null(st$input)) expect_true(st$input %in% seen, info = s)
            if (k != "preprocess" && is.null(st$input))
                expect_true(st$kind %in% c("source", "groups"), info = s)
            if (k != "preprocess") expect_true(is.function(st$code), info = s)
            seen <- c(seen, s)
        }
    }
})

test_that("categorical columns hold 2 to 200 cell types", {
    m <- data.frame(cell_ID = paste0("c", 1:300), type = rep(c("A", "B", NA), 100),
        clus = rep(1:3, 100), area = seq(0.5, 150, by = 0.5), id = 1:300, one = "x")
    out <- .categorical_columns(m)
    expect_identical(names(out), c("cell_ID", "type", "clus"))
    expect_identical(out$clus[1:3], c("1", "2", "3"))
    expect_null(.categorical_columns(m[c("cell_ID", "area")]))
})

test_that("disk expression drops scaling and non-standard normalization", {
    steps <- .analysis_steps()
    mem  <- .default_values(steps, disk = FALSE)
    disk <- .default_values(steps, disk = TRUE)
    expect_identical(mem$normalize$scale, "TRUE")
    expect_identical(disk$normalize$scale, "FALSE")
    norm <- Find(function(p) p$id == "norm_methods", steps$normalize$params)
    expect_identical(vapply(.offered(norm$choices, TRUE), `[[`, "", "value"), "standard")
    expect_length(.offered(norm$choices, FALSE), 4L)
})

test_that("R values map to menu keys", {
    expect_identical(.value_key(1:10), "1:10")
    expect_identical(.value_key(0.5), "0.5")
    expect_identical(.value_key(100), "100")
    expect_identical(.value_key(TRUE), "TRUE")
    expect_identical(.value_key(NULL), "auto")
    expect_identical(.value_key("sNN"), "sNN")
})

test_that("number parameters take any value in range", {
    steps <- .analysis_steps()
    par <- function(s, id) Find(function(p) p$id == id, steps[[s]]$params)
    res <- par("leiden", "resolution")
    expect_identical(.param_key(res, 0.37), "0.37")
    expect_identical(.param_key(res, "0.37"), "0.37")
    expect_error(.param_key(res, 0), "at least")
    expect_error(.param_key(res, "abc"), "needs a number")
    pcs <- par("umap", "dimensions_to_use")
    expect_identical(.param_key(pcs, 1:17), "1:17")
    expect_identical(.param_key(pcs, 17), "1:17")
    expect_identical(.param_key(pcs, "2:15"), "2:15")
    expect_identical(.param_key(pcs, 2:15), "2:15")
    expect_identical(.param_r(pcs, "2:15"), 2:15)
    expect_error(.param_key(pcs, 12.5), "whole numbers")
    expect_error(.param_key(pcs, "5:3"), "at least 2 PCs")
    expect_error(.param_key(pcs, "0:3"), "PC 1 or later")
    expect_error(.param_key(pcs, "2:40", max_pcs = 38), "last PC")
    expect_error(.param_key(pcs, c(1, 3, 4)), "consecutive")
    nn <- par("umap", "n_neighbors")
    expect_identical(.param_key(nn, NULL), "auto")
    expect_identical(.param_key(nn, ""), "auto")
    expect_null(.param_r(nn, "auto"))
    expect_identical(.param_r(par("network", "k"), "12"), 12L)
    meth <- par("hvf", "method")
    expect_error(.param_key(meth, "nope"), "must be one of")
})

test_that("marker lists are read from lists, tables and CSV files", {
    l <- .parse_markers(list(A = c("X", "Y", "X", ""), B = "Z", C = character()))
    expect_identical(l, list(A = c("X", "Y"), B = "Z"))
    d <- data.frame(type = c("A", "A", "B"), gene = c("X", "Y", "Z"))
    expect_identical(.parse_markers(d), list(A = c("X", "Y"), B = "Z"))
    f <- tempfile(fileext = ".csv"); utils::write.csv(d, f, row.names = FALSE)
    expect_identical(.parse_markers(f), list(A = c("X", "Y"), B = "Z"))
    expect_identical(.parse_markers(NULL), list())
    expect_error(.parse_markers(list("X")), "named by cell type")
})

test_that("analysis messages from the viewer are accepted", {
    for (type in c("analysis_param", "analysis_labels", "analysis_cancel", "analysis_settings",
                   "analysis_region", "analysis_run", "analysis_add", "analysis_remove",
                   "analysis_history", "analysis_feature")) {
        msg <- .parse_ws_message(sprintf('{"type":"%s","data":{}}', type))
        expect_identical(msg$type, type)
    }
})

test_that("generated code follows the parameters", {
    p <- list(resolution = 0.5, n_iterations = 20)
    code <- .step_code("leiden", p, list(network = list(type = "kNN")), NULL)
    expect_match(code, 'nn_network_to_use = "kNN"', fixed = TRUE)
    expect_match(code, "resolution = 0.5", fixed = TRUE)
    expect_identical(.step_code("labels", list(), list(), NULL), "")
    expect_match(.step_code("labels", list(), list(), c(`1` = "T cell")),
        'c("1" = "T cell")', fixed = TRUE)
    steps <- .analysis_steps()
    expect_identical(steps$spatial_network$code(list(method = "kNN", k = 20L,
        maximum_distance_knn = NULL), list()),
        'g <- createSpatialNetwork(g, method = "kNN", k = 20, name = "lens_spatial")')
    expect_match(steps$spatial_network$code(list(method = "Delaunay", k = 20L), list()),
        'method = "Delaunay", name', fixed = TRUE)
    code <- steps$proximity$code(list(number_of_simulations = 1000L, adjust_method = "fdr"),
        list(groups = list(column_name = "cell_type")))
    expect_match(code, 'cluster_column = "cell_type", number_of_simulations = 1000, adjust_method = "fdr"',
        fixed = TRUE)
    expect_match(code, "cellProximityHeatmap(g, CPscore = cpe", fixed = TRUE)
})

# The steps on the 400 um MERSCOPE vault, against a stand-in viewer
mini_vault <- "/Users/jeffreysheridan/Documents/Projects/GiottoDev/vaults/render_mini_20261103/giotto_project"

test_that("a change reruns only the steps below it", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")

    v <- new.env()
    v$sent <- list(); v$panels <- list(); v$meta <- NULL
    v$connected <- function() TRUE
    v$send <- function(type, data = NULL)
        v$sent[[length(v$sent) + 1L]] <- list(type = type, data = data)
    v$push_panel <- function(spec, data = NULL, id = NULL, title = NULL,
                             where = "tab", ref = NULL) v$panels[[id]] <- spec
    v$push_metadata <- function(x, ...) v$meta <- x

    colon_markers <- list(
        Epithelial  = c("EPCAM", "KRT20", "CDX2", "CDH1", "MUC2", "LGR5"),
        Fibroblast  = c("COL1A2", "COL3A1", "LUM", "PDGFRA", "FAP", "SFRP2"),
        Endothelial = c("PECAM1", "VWF", "CDH5", "KDR", "PLVAP", "ENG"),
        T_cell      = c("CD3E", "CD3D", "CD2", "CD8A", "CD4", "TRAC", "IL7R"),
        Myeloid     = c("CD68", "CD163", "CD14", "LYZ", "CSF1R", "ITGAM"))
    a <- LensAnalysis$new(v, g, cell_markers = colon_markers, params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        auto_type = list(min_overlap_genes = 2)))
    on.exit(a$close(), add = TRUE)
    a$wait(300)
    st <- vapply(a$status, `[[`, "", "status")
    expect_true(all(st == "done"), info = paste(names(st), st, collapse = ", "))
    expect_setequal(names(v$panels), c("qc-cells", "qc-feats", "pca-elbow"))
    expect_true(all(c("qc_pass", "umap_1", "umap_2", "leiden_clus", "cell_type",
        "cell_type_auto", "cell_type_auto_score") %in% names(v$meta)))
    priv <- a$.__enclos_env__$private
    n_cl <- length(unique(stats::na.omit(v$meta$leiden_clus)))
    expect_identical(nrow(priv$suggestions), n_cl)
    expect_true(all(a$labels() %in% names(colon_markers)))
    expect_length(priv$suggested, n_cl)
    expect_true(all(v$meta$cell_type[!is.na(v$meta$leiden_clus)] %in% names(colon_markers)))
    expect_match(a$code(), "runPAGEEnrich(g, sign_matrix = sign", fixed = TRUE)
    leiden_before <- a$status$leiden
    a$set("auto_type", method = "hypergeometric")
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_identical(a$status$leiden, leiden_before)
    expect_identical(nrow(v$meta), 2090L)
    expect_identical(v$meta$qc_pass == "pass", v$meta$qc_nr_feats >= 20)

    secs <- function() vapply(a$status, function(s) s$secs %||% NA_real_, 1)
    before <- secs()
    a$set("umap", min_dist = 0.3)
    a$wait(120)
    after <- secs()
    expect_identical(after[names(after) != "umap"], before[names(before) != "umap"])

    n_before <- sum(v$meta$qc_pass == "pass")
    a$set("filter", min_det_feats_per_cell = 50)
    a$wait(300)
    expect_lt(sum(v$meta$qc_pass == "pass"), n_before)
    expect_identical(v$meta$qc_pass == "pass", v$meta$qc_nr_feats >= 50)
    expect_true(all(is.na(v$meta$leiden_clus[v$meta$qc_pass == "removed"])))

    a$set("filter", expression_threshold = 5, min_det_feats_per_cell = 150)
    a$wait(300)
    expect_identical(a$status$filter$status, "done")
    expect_true(all(v$meta$qc_pass == "removed"))
    expect_true(all(vapply(a$status[setdiff(names(a$status), c("region", "filter"))],
        `[[`, "", "status") == "blocked"))
    expect_match(a$status$leiden$message, "QC filter")
    expect_false("leiden_clus" %in% names(v$meta))
    a$set("filter", expression_threshold = 1, min_det_feats_per_cell = 50)
    a$wait(300)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "done"))
    expect_identical(v$meta$qc_pass == "pass", v$meta$qc_nr_feats >= 50)
    expect_false(anyNA(v$meta$leiden_clus[v$meta$qc_pass == "pass"]))

    a$labels(c(`1` = "epithelial"))
    a$wait(60)
    expect_true("epithelial" %in% v$meta$cell_type)
    expect_false("1" %in% names(priv$suggested))
    a$set("auto_type", method = "PAGE")
    a$wait(120)
    expect_identical(unname(a$labels()["1"]), "epithelial")
    expect_error(a$set("leiden", resolution = -1), "at least")

    # Any value: a resolution off the menu, 17 PCs
    a$set("network", dimensions_to_use = 17)
    a$wait(120)
    expect_identical(a$params()$network$dimensions_to_use, 1:17)
    a$set("umap", dimensions_to_use = 2:15)
    a$wait(120)
    expect_identical(a$status$umap$status, "done")
    expect_identical(a$params()$umap$dimensions_to_use, 2:15)
    expect_match(a$code(), "dimensions_to_use = 2:15", fixed = TRUE)
    expect_error(a$set("umap", dimensions_to_use = "2:500"), "last PC")
    all_labels <- stats::setNames(paste0("type_", sort(unique(as.character(v$meta$leiden_clus)))),
        sort(unique(as.character(v$meta$leiden_clus))))
    a$labels(all_labels)
    a$wait(60)
    before <- a$labels()
    a$set("leiden", resolution = 1.05)
    a$wait(120)
    carried <- a$labels()
    carried <- carried[setdiff(names(carried), names(priv$suggested))]
    expect_gt(length(carried), 0L)
    expect_true(all(carried %in% before))
    a$set("leiden", resolution = 1)
    a$wait(120)
    expect_identical(a$labels(), before)
    expect_true(all(unname(before) %in% v$meta$cell_type))
    # A region: the steps run on part of the tissue
    whole <- a$params(); n_all <- nrow(v$meta)
    region_ids <- utils::head(v$meta$cell_ID, 600)
    a$region(region_ids)
    a$wait(300)
    expect_identical(a$status$region$status, "done")
    expect_match(a$status$region$summary, "600 of 2090")
    expect_identical(nrow(v$meta), n_all)
    outside <- !v$meta$cell_ID %in% region_ids
    expect_true(all(is.na(v$meta$qc_pass[outside])))
    expect_true(all(is.na(v$meta$leiden_clus[outside])))
    expect_true(any(!is.na(v$meta$leiden_clus[!outside])))
    expect_match(a$code(), "subsetGiotto", fixed = TRUE)
    a$save_settings("region")
    a$region(NULL)
    a$wait(300)
    expect_match(a$status$region$summary, "whole tissue")
    expect_true(sum(!is.na(v$meta$qc_pass)) == n_all)
    a$restore_settings("region")
    expect_identical(a$region(), sort(region_ids))
    a$region(NULL)
    a$wait(300)
    a$remove_settings("region")
    v$selection <- character()
    expect_error(a$handle("analysis_region", list(action = "selection")), "select cells first")

    # Saved settings
    a$save_settings("before")
    p_saved <- a$params(); lab_saved <- a$labels(); meta_saved <- v$meta$cell_type
    a$set("leiden", resolution = 0.3)
    a$set("umap", min_dist = 0.5)
    a$wait(120)
    a$labels(c(`1` = "changed"))
    a$wait(60)
    expect_false(identical(a$params(), p_saved))
    a$restore_settings("before")
    a$wait(120)
    expect_identical(a$params(), p_saved)
    expect_identical(a$labels(), lab_saved)
    expect_identical(v$meta$cell_type, meta_saved)
    expect_identical(a$settings()$name, "before")
    f <- tempfile(fileext = ".json")
    a$write_settings(f)
    a$remove_settings("before")
    expect_identical(nrow(a$settings()), 0L)
    a$set("leiden", resolution = 0.3)
    a$wait(120)
    a$read_settings(f)
    a$restore_settings("before")
    a$wait(120)
    expect_identical(a$params(), p_saved)
    expect_identical(a$labels(), lab_saved)
    expect_error(a$restore_settings("nope"), "no saved settings")
    a$handle("analysis_settings", list(action = "save", name = "from viewer"))
    expect_true("from viewer" %in% a$settings()$name)

    expect_s4_class(a$gobject(), "giotto")
})

test_that("the Analysis panel drives the steps from the page", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- suppressMessages(launch_lens_analysis(g, open = FALSE, params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20))))
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url, width = 1600, height = 900)
    on.exit(br$close(), add = TRUE)

    expect_true(pump_until(function() v$connected(), 30))
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=analysis] .an-step')", 60))
    v$analysis$wait(300)
    expect_true(browser_wait(br,
        "document.querySelectorAll('[data-panel=analysis] .an-step.an-done').length === 10", 30))
    expect_true(browser_wait(br,
        "window.__giottolens.store.getState().colorBy === 'leiden_clus'", 30))
    expect_true(browser_wait(br,
        "document.querySelectorAll('[data-panel=analysis] .an-linput').length > 0", 30))

    # A menu change on the page reaches R and reruns the step
    br$js("(() => { const s = document.querySelector('[data-step=leiden] input[data-param=resolution]');
        s.value = '0.37'; s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function()
        identical(v$analysis$params()$leiden$resolution, 0.37), 10))
    v$analysis$wait(120)
    expect_true(browser_wait(br,
        "document.querySelector('[data-step=leiden]').classList.contains('an-done')", 30))

    # A change from R shows in the page's menu
    v$analysis$set("umap", min_dist = 0.3)
    expect_true(browser_wait(br,
        "document.querySelector('[data-step=umap] input[data-param=min_dist]').value === '0.3'", 30))

    # A label typed on the page names the cells
    br$js("(() => { const i = document.querySelector('.an-linput[data-cluster=\"1\"]');
        i.value = 'epithelial'; i.dispatchEvent(new Event('input')); })()")
    expect_true(pump_until(function() identical(unname(v$analysis$labels()["1"]), "epithelial"), 10))
    v$analysis$wait(60)

    # Spatial interactions, added from the dialog, runs when Run all is clicked
    br$js("document.querySelector('[data-panel=analysis] .an-add').click()")
    expect_true(browser_wait(br, "!!document.querySelector('.an-modal [data-entry=interactions]')", 10))
    br$js("document.querySelector('.an-modal [data-entry=interactions]').click()")
    expect_true(browser_wait(br,
        "document.querySelector('.an-modal .an-cat-title').textContent === 'Spatial interactions'", 10))
    br$js("document.querySelector('.an-modal .an-primary').click()")
    expect_true(pump_until(function() "interactions" %in% names(v$analysis$analyses()), 10))
    expect_true(browser_wait(br, "!!document.querySelector('[data-step=proximity]')", 10))
    expect_identical(v$analysis$status$proximity$status, "stale")
    v$analysis$set("proximity", number_of_simulations = 50)
    br$js("document.querySelector('[data-panel=analysis] .an-run[data-run=interactions]').click()")
    expect_true(pump_until(function()
        v$analysis$status$proximity$status %in% c("queued", "running", "done"), 10))
    v$analysis$wait(300)
    expect_true(browser_wait(br,
        "document.querySelector('[data-step=proximity]').classList.contains('an-done')", 30))
    expect_length(br$errors(), 0L)
})

test_that("Automatic types waits for a marker list", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- new.env(); v$connected <- function() TRUE; v$send <- function(...) NULL
    v$push_panel <- function(...) NULL; v$push_metadata <- function(x, ...) v$meta <- x
    a <- LensAnalysis$new(v, g, params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20)))
    on.exit(a$close(), add = TRUE)
    a$wait(300)
    expect_identical(a$status$auto_type$status, "blocked")
    expect_match(a$status$auto_type$message, "cell_markers")
    expect_identical(a$status$labels$status, "done")
    expect_false(grepl("runPAGEEnrich", a$code(), fixed = TRUE))
    a$cell_markers(data.frame(type = c("Epithelial", "Epithelial", "Fibroblast", "Fibroblast"),
        gene = c("EPCAM", "KRT20", "COL1A2", "LUM")))
    a$set("auto_type", min_overlap_genes = 2)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "error")
    expect_match(a$status$auto_type$message, "more than 2")
    a$set("auto_type", min_overlap_genes = 1)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_true(all(stats::na.omit(v$meta$cell_type_auto) %in% c("Epithelial", "Fibroblast")))
})

# A stand-in viewer that records what the analysis sends
.fake_viewer <- function() {
    v <- new.env()
    v$sent <- list(); v$panels <- list(); v$meta <- NULL
    v$connected <- function() TRUE
    v$send <- function(type, data = NULL)
        v$sent[[length(v$sent) + 1L]] <- list(type = type, data = data)
    v$push_panel <- function(spec, data = NULL, id = NULL, title = NULL,
                             where = "tab", ref = NULL) v$panels[[id]] <- spec
    v$push_metadata <- function(x, ...) v$meta <- x
    v$removed <- character()
    v$remove_panel <- function(id) v$removed <- c(v$removed, id)
    v
}

test_that("Spatial interactions run only when asked", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "interactions", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        groups = list(column = "object:cell_type"),
        proximity = list(number_of_simulations = 50)))
    on.exit(a$close(), add = TRUE)
    ist <- c("groups", "spatial_network", "proximity")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    priv <- a$.__enclos_env__$private
    expect_identical(priv$resolve_column("groups"), "object:cell_type")
    sch <- priv$schema()
    expect_identical(vapply(sch$pipelines, `[[`, "", "id"), c("preprocess", "interactions"))
    col <- Find(function(x) x$id == "groups", sch$steps)$params[[1L]]
    expect_identical(col$type, "choice")
    expect_true(all(c("object:cell_type", "object:leiden_clus", "analysis:cell_type") %in%
        vapply(col$choices, `[[`, "", "value")))

    a$run(step = "spatial_network")
    a$wait(120)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_match(a$status$groups$summary, "cell_type")
    expect_null(v$panels$proximity)

    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$proximity$summary, "pairs")
    spec <- v$panels$proximity
    expect_identical(spec$mark$type, "rect")
    n_types <- length(unique(stats::na.omit(GiottoClass::pDataDT(g)$cell_type)))
    expect_identical(nrow(spec$data$values), as.integer(n_types^2))
    fields <- c(spec$encoding$x$field, spec$encoding$y$field, spec$encoding$color$field,
        vapply(spec$encoding$tooltip, `[[`, "", "field"))
    expect_true(all(fields %in% names(spec$data$values)))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
    expect_false(anyNA(spec$data$values$p_adj_higher))
    expect_match(a$code("interactions"), 'cluster_column = "cell_type", number_of_simulations = 50',
        fixed = TRUE)

    secs <- a$status$groups$secs
    a$set("spatial_network", k = 10)
    a$wait(30)
    expect_identical(unname(st()), c("done", "stale", "stale"))
    expect_identical(a$status$groups$secs, secs)
    a$handle("analysis_run", list(pipeline = "interactions"))
    expect_true(all(st()[-1L] %in% c("queued", "running")))
    a$cancel()
    a$wait(30)
    expect_true(all(st()[-1L] == "stale"))

    a$set("groups", column = "object:leiden_clus")
    expect_identical(priv$resolve_column("groups"), "object:leiden_clus")
    a$run(step = "proximity")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$groups$summary, "leiden_clus")
    expect_error(a$run("nope"), "no analysis")
})

test_that("History brings back runs; genes color cells; analyses are added and removed", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20)))
    on.exit(a$close(), add = TRUE)
    a$wait(300)
    expect_identical(names(a$analyses()), "preprocess")
    expect_true("interactions" %in% a$catalog()$id)
    expect_identical(nrow(a$history("preprocess")), 1L)
    expect_error(a$remove("preprocess"), "cannot be removed")

    a$handle("analysis_add", list(id = "interactions",
        params = list(proximity = list(number_of_simulations = "20"))))
    expect_identical(names(a$analyses()), c("preprocess", "interactions"))
    expect_identical(a$params()$proximity$number_of_simulations, 20L)
    a$run("interactions")
    a$wait(300)
    a$set("spatial_network", k = 10)
    a$run("interactions")
    a$wait(300)
    h <- a$history("interactions")
    expect_identical(nrow(h), 2L)
    expect_identical(h$current, c(FALSE, TRUE))
    first <- h$run[[1L]]
    secs <- a$status$proximity$secs
    v$panels$proximity <- NULL
    a$restore_run("interactions", first)
    expect_identical(a$params()$spatial_network$k, 20L)
    expect_true(all(vapply(a$status[c("groups", "spatial_network", "proximity")], `[[`, "",
        "status") == "done"))
    expect_false(is.null(v$panels$proximity))
    a$wait(30)
    expect_identical(a$history("interactions")$current, c(TRUE, FALSE))

    a$handle("analysis_feature", list(step = "proximity", feat = "MYC"))
    a$wait(60)
    expect_true("expr_MYC" %in% names(v$meta))
    fb <- Filter(function(m) m$type == "analysis_feature", v$sent)
    expect_identical(fb[[length(fb)]]$data$values, "normalized")
    a$handle("analysis_feature", list(step = "proximity", feat = "CDX2"))
    a$wait(60)
    expect_true("expr_CDX2" %in% names(v$meta))
    expect_false("expr_MYC" %in% names(v$meta))

    a$remove("interactions")
    expect_identical(names(a$analyses()), "preprocess")
    expect_null(a$status$proximity)
    expect_true("proximity" %in% v$removed)
    a$add("interactions")
    expect_identical(nrow(a$history("interactions")), 2L)
    a$save_settings("both")
    a$remove("interactions")
    a$restore_settings("both")
    expect_true("interactions" %in% names(a$analyses()))
})

test_that("Spatial interactions follow the cell types of the Preprocessing tab", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "interactions", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        proximity = list(number_of_simulations = 50)))
    on.exit(a$close(), add = TRUE)
    a$wait(300)
    priv <- a$.__enclos_env__$private
    pre <- vapply(a$status[priv$pipelines$preprocess$steps], `[[`, "", "status")
    expect_true(all(pre[names(pre) != "auto_type"] == "done"))
    st <- function() vapply(a$status[c("groups", "spatial_network", "proximity")], `[[`, "", "status")
    expect_true(all(st() == "stale"))
    expect_identical(priv$resolve_column("groups"), "analysis:cell_type")
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    n_typed <- sum(!is.na(v$meta$cell_type))
    expect_match(a$status$groups$summary, paste0("^", n_typed, " cells"))

    a$labels(c(`1` = "epithelial"))
    a$wait(60)
    expect_true("epithelial" %in% v$meta$cell_type)
    expect_true(all(st() == "stale"))
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_true(any(grepl("epithelial", v$panels$proximity$data$values$pair)))
})
