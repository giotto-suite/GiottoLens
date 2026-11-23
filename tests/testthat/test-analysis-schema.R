# ── Catalog and step schema ─────────────────────────────────────────────────

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
            } else if (p$type %in% c("column", "text", "values", "spatial_network")) {
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
            for (par in st$params)
                expect_true(is.character(par$help) && length(par$help) == 1L &&
                    nzchar(par$help), info = paste(s, par$id, "help"))
            for (par in st$params) if (isTRUE(par$advanced))
                expect_true(nzchar(par$help %||% ""), info = paste(s, par$id, "advanced help"))
            for (par in st$params) for (ctrl in names(par$show_if)) {
                cp <- .par(st, ctrl)
                expect_false(is.null(cp), info = paste(s, par$id, "show_if", ctrl))
                keys <- if (identical(cp$type, "number") && isTRUE(cp$auto)) "auto"
                    else if (identical(cp$type, "spatial_network")) "new"
                    else vapply(cp$choices, `[[`, "", "value")
                expect_true(all(par$show_if[[ctrl]] %in% keys),
                    info = paste(s, par$id, "show_if"))
            }
            seen <- c(seen, s)
        }
    }
})

test_that("help comes from the Giotto help files where a parameter passes an argument", {
    skip_if_not_installed("GiottoClass")
    net <- .analysis_catalog()$interactions$steps$spatial_network
    expect_identical(.par(net, "k")$help_src, "createSpatialNetwork(k)")
    expect_match(.par(net, "delaunay_method")$help, "delaunayn_geometry", fixed = TRUE)
    grp <- .analysis_catalog()$interactions$steps$groups
    expect_null(grp$params[[1L]]$help_src)
    expect_match(grp$params[[1L]]$help, "cell metadata label", fixed = TRUE)
})

test_that("parameters that do not apply are left out of the key", {
    net <- .step_network(input = NULL)
    k <- .par(net, "k")
    expect_true(.param_shown(k, list(network = "new", method = "kNN")))
    expect_false(.param_shown(k, list(network = "new", method = "Delaunay")))
    expect_false(.param_shown(k, list(network = "Delaunay_network", method = "kNN")))
    method <- .par(net, "method")
    expect_true(.param_shown(method, list(network = "new", method = "Delaunay")))
    expect_false(.param_shown(method, list(network = "Delaunay_network")))
})

test_that("Spatial genes and co-expression entries have their fields and steps", {
    cat <- .analysis_catalog()
    expect_true(all(c("spatial_genes", "coexpression") %in% names(cat)))
    sg <- cat$spatial_genes
    expect_identical(sg$label, "Spatial genes")
    expect_identical(sg$order, 20)
    expect_false(sg$auto)
    expect_identical(names(sg$steps), c("sg_source", "sg_network", "sg_genes"))
    expect_identical(sg$steps$sg_source$kind, "source")
    expect_identical(sg$steps$sg_network$input, "sg_source")
    expect_identical(sg$steps$sg_genes$input, "sg_network")
    keys <- vapply(sg$steps$sg_genes$params[[1L]]$choices, `[[`, "", "value")
    expect_identical(keys, c("binspect_kmeans", "binspect_rank", "silhouette", "moran", "geary"))
    expect_match(sg$description, "one score per gene for the whole tissue", fixed = TRUE)

    cm <- cat$coexpression
    expect_identical(cm$label, "Spatial co-expression modules")
    expect_identical(cm$order, 30)
    expect_false(cm$auto)
    expect_identical(names(cm$steps), c("cm_source", "cm_network", "cm_genes", "cm_modules"))
    expect_identical(cm$steps$cm_modules$input, "cm_genes")
    ids <- unlist(lapply(cat, function(e) names(e$steps)), use.names = FALSE)
    expect_false(anyDuplicated(ids) > 0)
    for (e in list(sg, cm)) for (s in names(e$steps))
        expect_true(is.function(e$steps[[s]]$code), info = s)
})

test_that("Niches and Interaction-changed genes entries are complete", {
    cat <- .analysis_catalog()
    expect_true(all(c("niches", "icf") %in% names(cat)))
    nc <- cat$niches
    expect_identical(nc$label, "Niches")
    expect_identical(nc$order, 40)
    expect_false(nc$auto)
    expect_identical(names(nc$steps), c("nc_groups", "nc_network", "nc_proportions",
        "nc_kmeans"))
    expect_identical(nc$steps$nc_groups$kind, "groups")
    expect_null(nc$steps$nc_groups$input)
    expect_identical(nc$steps$nc_network$input, "nc_groups")
    expect_identical(nc$steps$nc_proportions$input, "nc_network")
    expect_identical(nc$steps$nc_kmeans$input, "nc_proportions")
    icf <- cat$icf
    expect_identical(icf$label, "Interaction-changed genes")
    expect_identical(icf$order, 50)
    expect_false(icf$auto)
    expect_identical(names(icf$steps), c("icf_source", "icf_groups", "icf_network",
        "icf_test"))
    expect_identical(icf$steps$icf_source$kind, "source")
    expect_identical(icf$steps$icf_groups$kind, "groups")
    expect_identical(icf$steps$icf_groups$input, "icf_source")
    expect_identical(icf$steps$icf_test$input, "icf_network")
    for (e in list(nc, icf)) for (f in c("brief", "description"))
        expect_true(is.character(e[[f]]) && length(e[[f]]) == 1L && nzchar(e[[f]]))
})

# ── Parameters and values ───────────────────────────────────────────────────

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
    norm <- .par(steps$normalize, "norm_methods")
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
    res <- .par(steps$leiden, "resolution")
    expect_identical(.param_key(res, 0.37), "0.37")
    expect_identical(.param_key(res, "0.37"), "0.37")
    expect_error(.param_key(res, 0), "at least")
    expect_error(.param_key(res, "abc"), "needs a number")
    pcs <- .par(steps$umap, "dimensions_to_use")
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
    nn <- .par(steps$umap, "n_neighbors")
    expect_identical(.param_key(nn, NULL), "auto")
    expect_identical(.param_key(nn, ""), "auto")
    expect_null(.param_r(nn, "auto"))
    expect_identical(.param_r(.par(steps$network, "k"), "12"), 12L)
    meth <- .par(steps$hvf, "method")
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

test_that("values and network parameters take names", {
    v <- .values_param(c("scaled", "normalized"))
    expect_identical(v$type, "values")
    expect_identical(.param_key(v, NULL), "")
    expect_identical(.param_key(v, " custom "), "custom")
    expect_error(.param_key(v, c("a", "b")), "one expression name")
    expect_identical(.param_r(v, "raw"), "raw")
    net <- .par(.step_network(input = NULL), "network")
    expect_identical(.param_key(net, NULL), "new")
    expect_identical(.param_key(net, "Delaunay_network"), "Delaunay_network")
    expect_identical(.values_of(list(), list(list(), list(expression_values = "raw"))), "raw")
    expect_identical(.values_of(list(expression_values = "scaled"),
        list(list(expression_values = "raw"))), "scaled")
    expect_identical(.values_of(list(), list()), "normalized")
    expect_null(.preferred_network(character()))
    expect_identical(.preferred_network(c("mine", "kNN_network", "Delaunay_network")),
        "Delaunay_network")
    expect_identical(.preferred_network(c("mine", "other")), "mine")
})

# ── Messages ────────────────────────────────────────────────────────────────

test_that("analysis messages from the viewer are accepted", {
    for (type in c("analysis_param", "analysis_labels", "analysis_cancel", "analysis_settings",
                   "analysis_region", "analysis_run", "analysis_add", "analysis_remove",
                   "analysis_history", "analysis_feature")) {
        msg <- .parse_ws_message(sprintf('{"type":"%s","data":{}}', type))
        expect_identical(msg$type, type)
    }
})

# ── Advanced parameters and generated code ──────────────────────────────────

test_that("advanced parameters take Giotto's defaults", {
    steps <- .analysis_steps()
    expect_true(all(c("library_size_norm", "scalefactor", "logbase", "scale_order", "theta") %in%
        .adv_ids(steps$normalize)))
    expect_true(all(c("n_top_feats", "expression_threshold", "nr_expression_groups", "theta",
        "reverse_log_scale", "logbase", "random_subset", "calc_gini", "set_seed",
        "seed_number") %in% .adv_ids(steps$hvf)))
    expect_true(all(c("center", "method", "set_seed", "seed_number") %in% .adv_ids(steps$pca)))
    expect_true(all(c("spread", "n_epochs", "init", "n_components", "nn_engine", "method",
        "batch", "set_seed", "seed_number") %in% .adv_ids(steps$umap)))
    expect_true(all(c("engine", "minimum_shared", "top_shared", "ef", "keep_knn") %in%
        .adv_ids(steps$network)))
    expect_true(all(c("n_iterations", "objective_function", "beta", "weights", "set_seed",
        "seed_number") %in% .adv_ids(steps$leiden)))
    expect_true(all(c("subset_clusters", "min_feats", "pval", "logFC", "min_expression",
        "min_detection", "min_expression_gini", "min_detection_gini", "detection_threshold",
        "min_length", "rank_score") %in% .adv_ids(steps$markers)))
    expect_true(all(c("output_enrichment", "p_value", "include_depletion",
        "reverse_log_scale", "logbase") %in% .adv_ids(steps$auto_type)))
    expect_true(all(c("maximum_distance_knn", "knn_method", "maximum_distance_delaunay",
        "delaunay_method", "options", "minimum_k", "dimensions") %in%
        .adv_ids(steps$spatial_network)))
    expect_identical(.adv_ids(steps$proximity), c("set_seed", "seed_number"))
    for (s in c("normalize", "hvf", "pca", "umap", "network", "leiden", "markers",
                "auto_type", "spatial_network", "proximity")) {
        basic <- Filter(function(p) !isTRUE(p$advanced), steps[[s]]$params)
        expect_gt(length(basic), 0L)
    }
    d <- .default_values(steps, disk = FALSE)
    expect_identical(d$normalize[c("library_size_norm", "scalefactor", "logbase",
        "scale_order", "theta")], list(library_size_norm = "TRUE", scalefactor = "6000",
        logbase = "2", scale_order = "first_feats", theta = "100"))
    expect_identical(d$hvf[c("n_top_feats", "nr_expression_groups", "random_subset",
        "seed_number")], list(n_top_feats = "2000", nr_expression_groups = "20",
        random_subset = "auto", seed_number = "1234"))
    expect_identical(d$umap[c("n_components", "n_epochs", "init", "nn_engine", "method")],
        list(n_components = "2", n_epochs = "auto", init = "auto", nn_engine = "giotto",
            method = "umap2"))
    expect_identical(d$network[c("engine", "minimum_shared", "top_shared", "ef")],
        list(engine = "hnsw", minimum_shared = "5", top_shared = "3", ef = "200"))
    expect_identical(d$leiden[c("objective_function", "beta", "weights")],
        list(objective_function = "modularity", beta = "0.01", weights = "auto"))
    expect_identical(d$markers[c("min_feats", "pval", "logFC", "rank_score")],
        list(min_feats = "10", pval = "0.01", logFC = "0.5", rank_score = "auto"))
    expect_identical(d$auto_type$reverse_log_scale, "auto")
    expect_identical(d$spatial_network[c("method", "delaunay_method",
        "maximum_distance_delaunay", "options", "minimum_k", "dimensions")],
        list(method = "kNN", delaunay_method = "delaunayn_geometry",
            maximum_distance_delaunay = "auto", options = "Pp", minimum_k = "0",
            dimensions = "all"))
    offered <- function(s, id, disk) vapply(.offered(.par(steps[[s]], id)$choices, disk),
        `[[`, "", "value")
    expect_identical(offered("pca", "method", TRUE), c("auto", "random"))
    expect_identical(offered("hvf", "reverse_log_scale", TRUE), "FALSE")
    expect_true(all(c("deldir", "delaunayn_geometry") %in%
        offered("spatial_network", "delaunay_method", TRUE)))
    expect_identical("RTriangle" %in% offered("spatial_network", "delaunay_method", TRUE),
        requireNamespace("RTriangle", quietly = TRUE))
    expect_identical(.param_key(.par(steps$leiden, "weights"), NA),
        "NA")
})

test_that("generated code includes advanced arguments that differ from their defaults", {
    steps <- .analysis_steps()
    d <- .default_values(steps, disk = FALSE)
    rv <- function(s, ...) {
        p <- list()
        for (par in steps[[s]]$params) p[par$id] <- list(.param_r(par, d[[s]][[par$id]]))
        ov <- list(...)
        for (k in names(ov)) p[k] <- list(ov[[k]])
        p
    }
    up <- list(normalize = list(scale = FALSE, log_norm = TRUE), network = list(type = "sNN"))
    expect_identical(steps$umap$code(rv("umap"), up), paste0("g <- runUMAP(g, ",
        "expression_values = \"normalized\", dim_reduction_name = \"pca\", ",
        "dimensions_to_use = 1:10, min_dist = 0.05, name = \"umap\")"))
    expect_match(steps$umap$code(rv("umap", n_epochs = 100L, init = "pca", spread = 2), up),
        "min_dist = 0.05, spread = 2, init = \"pca\"", fixed = TRUE)
    expect_match(steps$umap$code(rv("umap", n_epochs = 100L), up), "n_epochs = 100", fixed = TRUE)
    expect_identical(steps$normalize$code(rv("normalize", scale = FALSE), up), paste0(
        "g <- normalizeGiotto(g, norm_methods = \"standard\", log_norm = TRUE, ",
        "scale_feats = FALSE, scale_cells = FALSE)"))
    expect_match(steps$normalize$code(rv("normalize", logbase = 10, scalefactor = 5000), up),
        "scalefactor = 5000, log_norm = TRUE, logbase = 10", fixed = TRUE)
    expect_false(grepl("scale_order", steps$normalize$code(rv("normalize", scale = FALSE,
        scale_order = "first_cells"), up)))
    expect_false(grepl("theta", steps$normalize$code(rv("normalize", theta = 50), up)))
    expect_match(steps$normalize$code(rv("normalize", norm_methods = "pearson_resid",
        theta = 50), up), "theta = 50", fixed = TRUE)
    hvf <- steps$hvf$code(rv("hvf", n_top_feats = 300L, random_subset = 1000L,
        set_seed = FALSE, seed_number = 5L), up)
    expect_match(hvf, "n_top_feats = 300, random_subset = 1000, set_seed = FALSE)", fixed = TRUE)
    expect_false(grepl("seed_number", hvf))
    expect_match(steps$pca$code(rv("pca", method = "random", center = FALSE), up),
        "feats_to_use = \"hvf\", center = FALSE, scale_unit = TRUE, ncp = 100, method = \"random\"",
        fixed = TRUE)
    expect_match(steps$pca$code(rv("pca", feats_to_use = NULL), up), "feats_to_use = NULL",
        fixed = TRUE)
    expect_false(grepl("ef =", steps$network$code(rv("network", engine = "dbscan", ef = 50L),
        up)))
    expect_match(steps$network$code(rv("network"), up), "engine = \"hnsw\"", fixed = TRUE)
    expect_match(steps$network$code(rv("network", engine = "hnsw", ef = 50L), up),
        "engine = \"hnsw\", ef = 50", fixed = TRUE)
    expect_false(grepl("minimum_shared", steps$network$code(rv("network", type = "kNN",
        minimum_shared = 2L), up)))
    expect_identical(steps$leiden$code(rv("leiden"), up), paste0("g <- doLeidenCluster(g, ",
        "nn_network_to_use = \"sNN\", network_name = \"sNN.pca\", resolution = 1, ",
        "name = \"leiden_clus\")"))
    expect_match(steps$leiden$code(rv("leiden", objective_function = "CPM", weights = NA,
        seed_number = 7L), up), "objective_function = \"CPM\", weights = NA, seed_number = 7",
        fixed = TRUE)
    mk <- steps$markers$code(rv("markers", method = "gini", rank_score = 2L, pval = 0.05,
        subset_clusters = "1, 3"), up)
    expect_match(mk, "subset_clusters = c(\"1\", \"3\"), method = \"gini\"", fixed = TRUE)
    expect_match(mk, "rank_score = 2", fixed = TRUE)
    expect_false(grepl("pval", mk))
    expect_match(steps$markers$code(rv("markers", pval = 0.05), up), "pval = 0.05", fixed = TRUE)
    at <- steps$auto_type$code(rv("auto_type", p_value = TRUE, output_enrichment = "zscore"), up)
    expect_match(at, "min_overlap_genes = 5, output_enrichment = \"zscore\", p_value = TRUE",
        fixed = TRUE)
    expect_false(grepl("reverse_log_scale", at))
    expect_match(steps$auto_type$code(rv("auto_type", reverse_log_scale = FALSE), up),
        "reverse_log_scale = FALSE", fixed = TRUE)
    expect_identical(steps$labels$code(list(labels = list(`1` = "T cell")), up),
        "g <- annotateGiotto(g, annotation_vector = c(\"1\" = \"T cell\"), cluster_column = \"leiden_clus\", name = \"cell_type\")")
    sn <- steps$spatial_network
    expect_identical(sn$code(rv("spatial_network"), list()),
        "g <- createSpatialNetwork(g, method = \"kNN\", k = 20, name = \"kNN_network\")")
    expect_identical(sn$code(rv("spatial_network", method = "Delaunay"), list()), paste0(
        "g <- createSpatialNetwork(g, method = \"Delaunay\", ",
        "delaunay_method = \"delaunayn_geometry\", name = \"Delaunay_network\")"))
    expect_identical(sn$code(rv("spatial_network", method = "Delaunay",
        delaunay_method = "deldir", maximum_distance_delaunay = 40, minimum_k = 1L), list()),
        paste0("g <- createSpatialNetwork(g, method = \"Delaunay\", ",
            "maximum_distance_delaunay = 40, minimum_k = 1, name = \"Delaunay_network\")"))
    expect_identical(sn$code(rv("spatial_network", method = "radius", k = 5L,
        dimensions = 1:2), list()), paste0("g <- createSpatialNetwork(g, method = \"radius\", ",
        "radius = 30, dimensions = 1:2, name = \"radius_network\")"))
    expect_match(sn$code(rv("spatial_network", maximum_distance_knn = 30, options = "Qt"),
        list()), "k = 20, maximum_distance_knn = 30, name", fixed = TRUE)
    pr <- steps$proximity$code(rv("proximity", seed_number = 7L),
        list(groups = list(column_name = "cell_type")))
    expect_match(pr, "adjust_method = \"none\", seed_number = 7)", fixed = TRUE)
})
