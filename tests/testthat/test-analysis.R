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
                cp <- Find(function(q) identical(q$id, ctrl), st$params)
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
    par <- function(id) Find(function(q) q$id == id, net$params)
    expect_identical(par("k")$help_src, "createSpatialNetwork(k)")
    expect_match(par("delaunay_method")$help, "delaunayn_geometry", fixed = TRUE)
    grp <- .analysis_catalog()$interactions$steps$groups
    expect_null(grp$params[[1L]]$help_src)
    expect_match(grp$params[[1L]]$help, "cell metadata label", fixed = TRUE)
})

test_that("parameters that do not apply are left out of the key", {
    net <- .step_network(input = NULL)
    k <- Find(function(q) q$id == "k", net$params)
    expect_true(.param_shown(k, list(network = "new", method = "kNN")))
    expect_false(.param_shown(k, list(network = "new", method = "Delaunay")))
    expect_false(.param_shown(k, list(network = "Delaunay_network", method = "kNN")))
    method <- Find(function(q) q$id == "method", net$params)
    expect_true(.param_shown(method, list(network = "new", method = "Delaunay")))
    expect_false(.param_shown(method, list(network = "Delaunay_network")))
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
    steps <- .analysis_steps()
    p <- list(resolution = 0.5, n_iterations = 20)
    code <- steps$leiden$code(p, list(network = list(type = "kNN")))
    expect_match(code, 'nn_network_to_use = "kNN", network_name = "kNN.pca"', fixed = TRUE)
    expect_match(code, "resolution = 0.5", fixed = TRUE)
    expect_match(code, 'name = "leiden_clus")', fixed = TRUE)
    code <- steps$leiden$code(c(p, name = "clus_a"), list(network = list(type = "kNN",
        name = "nn_a")))
    expect_match(code, 'network_name = "nn_a"', fixed = TRUE)
    expect_match(code, 'name = "clus_a")', fixed = TRUE)
    expect_identical(steps$labels$code(list(labels = list()), list()), "")
    expect_identical(steps$labels$code(list(labels = list(`1` = "T cell"), name = "ct"),
        list(leiden = list(name = "clus_a"))), paste0('g <- annotateGiotto(g, ',
        'annotation_vector = c("1" = "T cell"), cluster_column = "clus_a", name = "ct")'))
    expect_identical(steps$spatial_network$code(list(network = "new", method = "kNN", k = 20L,
        maximum_distance_knn = NULL), list()),
        'g <- createSpatialNetwork(g, method = "kNN", k = 20, name = "kNN_network")')
    expect_match(steps$spatial_network$code(list(network = "new", method = "Delaunay",
        k = 20L, name = "near"), list()), 'method = "Delaunay", name = "near")', fixed = TRUE)
    expect_match(steps$spatial_network$code(list(network = "new", method = "Delaunay", k = 20L,
        delaunay_method = "delaunayn_geometry"), list()),
        'method = "Delaunay", delaunay_method = "delaunayn_geometry", name', fixed = TRUE)
    expect_identical(steps$spatial_network$code(list(network = "Delaunay_network",
        method = "kNN"), list()), "")
    expect_identical(.network_of(list(), list(list(network = "Delaunay_network"))),
        "Delaunay_network")
    expect_identical(.network_of(list(), list(list(), list(network = "new",
        method = "radius", name = ""))), "radius_network")
    code <- steps$proximity$code(list(number_of_simulations = 1000L, adjust_method = "fdr"),
        list(groups = list(column_name = "cell_type")))
    expect_match(code, 'cluster_column = "cell_type", number_of_simulations = 1000, adjust_method = "fdr"',
        fixed = TRUE)
    expect_match(code, "cellProximityHeatmap(g, CPscore = cpe", fixed = TRUE)
})

test_that("advanced parameters take Giotto's defaults", {
    steps <- .analysis_steps()
    adv <- function(s) vapply(Filter(function(p) isTRUE(p$advanced), steps[[s]]$params),
        `[[`, "", "id")
    expect_true(all(c("library_size_norm", "scalefactor", "logbase", "scale_order", "theta") %in%
        adv("normalize")))
    expect_true(all(c("n_top_feats", "expression_threshold", "nr_expression_groups", "theta",
        "reverse_log_scale", "logbase", "random_subset", "calc_gini", "set_seed",
        "seed_number") %in% adv("hvf")))
    expect_true(all(c("center", "method", "set_seed", "seed_number") %in% adv("pca")))
    expect_true(all(c("spread", "n_epochs", "init", "n_components", "nn_engine", "method",
        "batch", "set_seed", "seed_number") %in% adv("umap")))
    expect_true(all(c("engine", "minimum_shared", "top_shared", "ef", "keep_knn") %in%
        adv("network")))
    expect_true(all(c("n_iterations", "objective_function", "beta", "weights", "set_seed",
        "seed_number") %in% adv("leiden")))
    expect_true(all(c("subset_clusters", "min_feats", "pval", "logFC", "min_expression",
        "min_detection", "min_expression_gini", "min_detection_gini", "detection_threshold",
        "min_length", "rank_score") %in% adv("markers")))
    expect_true(all(c("output_enrichment", "p_value", "include_depletion",
        "reverse_log_scale", "logbase") %in% adv("auto_type")))
    expect_true(all(c("maximum_distance_knn", "knn_method", "maximum_distance_delaunay",
        "delaunay_method", "options", "minimum_k", "dimensions") %in% adv("spatial_network")))
    expect_identical(adv("proximity"), c("set_seed", "seed_number"))
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
    offered <- function(s, id, disk) vapply(.offered(Find(function(p) p$id == id,
        steps[[s]]$params)$choices, disk), `[[`, "", "value")
    expect_identical(offered("pca", "method", TRUE), c("auto", "random"))
    expect_identical(offered("hvf", "reverse_log_scale", TRUE), "FALSE")
    expect_true(all(c("deldir", "delaunayn_geometry") %in%
        offered("spatial_network", "delaunay_method", TRUE)))
    expect_identical("RTriangle" %in% offered("spatial_network", "delaunay_method", TRUE),
        requireNamespace("RTriangle", quietly = TRUE))
    expect_identical(.param_key(Find(function(p) p$id == "weights", steps$leiden$params), NA),
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

test_that("spatial network settings apply to their method only", {
    net <- .step_network(input = NULL)
    par <- function(id) Find(function(q) q$id == id, net$params)
    expect_true(.param_shown(par("radius"), list(network = "new", method = "radius")))
    expect_false(.param_shown(par("radius"), list(network = "new", method = "kNN")))
    expect_true(.param_shown(par("maximum_distance_delaunay"), list(network = "new",
        method = "Delaunay")))
    expect_false(.param_shown(par("maximum_distance_delaunay"), list(method = "kNN")))
    expect_true(.param_shown(par("options"), list(network = "new", method = "Delaunay",
        delaunay_method = "delaunayn_geometry")))
    expect_false(.param_shown(par("options"), list(method = "Delaunay",
        delaunay_method = "deldir")))
    expect_true(.param_shown(par("minimum_k"), list(network = "new", method = "radius")))
    expect_false(.param_shown(par("minimum_k"), list(network = "kNN_network")))
    expect_identical(is.null(par("S")), !requireNamespace("RTriangle", quietly = TRUE))
})

# The steps on the 400 um MERSCOPE vault, against a stand-in viewer
# The tests below run the steps, as jobs, on the analysis fixture
# (helper-analysis.R): 600 cells in three bands, each with ten marker genes.

test_that("an analysis runs nothing until asked, and its keys start at the snapshot", {
    r <- lens_analysis_rig(params = lens_analysis_params, start = FALSE)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    expect_identical(r$v$analysis(), a)
    later::run_now(0.5)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "stale"))
    expect_length(r$v$jobs()$id, 0L)
    expect_null(r$priv$lens_work())
    expect_error(r$v$push_panel(list(mark = "point"), id = "analysis"), "built-in panel")
    expect_match(a$.__enclos_env__$private$keys$filter,
        paste0("<snapshot:", r$priv$snapshot, "$"))
    # The page heard of it, and opens the panel
    sch <- Find(function(m) m$type == "analysis_schema", r$sent())
    expect_true(isTRUE(sch$data$open))

    a$run("preprocess")
    a$wait(300)
    expect_true(all(vapply(a$status, `[[`, "", "status")[names(a$status) != "auto_type"] == "done"))
    expect_match(r$priv$lens_work(), "an analysis")
    expect_error(suppressMessages(r$v$set_object(r$fx$g, feat_type = NULL)), "an analysis")
    suppressMessages(r$v$set_object(r$fx$g, feat_type = NULL, discard = TRUE))
    expect_null(r$priv$lens_analysis)
    expect_false(identical(r$v$analysis(), a))
})

test_that("an analysis's columns sit beside pulled ones, and a gene colors by item key", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    suppressMessages(r$v$pull("band"))
    a$set("umap", min_dist = 0.3)
    a$wait(120)
    expect_true(all(c("band", "umap_1", "leiden_clus") %in% r$priv$meta_names()))
    # A column the analysis no longer makes goes, with rules on it
    r$priv$rule_set <- list(meta = list(kind = "categories", space = "cell_type_auto",
        params = list(values = list("A"))))
    r$priv$own_columns("analysis", r$meta()[c("cell_ID", "qc_pass")])
    expect_false("leiden_clus" %in% r$priv$meta_names())
    expect_true("band" %in% r$priv$meta_names())

    a$handle("analysis_feature", list(step = "markers", feat = "gene03"))
    hit <- NULL
    expect_true(pump_until(function() {
        hit <<- Find(function(m) m$type == "set_color_by", r$sent())
        !is.null(hit)
    }, timeout = 60))
    key <- hit$data$column
    expect_match(key, "^@expression/rna/normalized/analysis%3A[0-9a-f]{16}/gene03$")
    expect_match(hit$data$item$url, "^session/items/")
    vals <- .read_meta_column(r$priv$items_dir(), r$priv$item_files[[key]])
    left <- r$fx$meta$band[match(r$priv$cell_ids, r$fx$meta$cell_ID)] == "A"
    expect_gt(mean(vals[left], na.rm = TRUE), mean(vals[!left], na.rm = TRUE) + 1)
    fb <- Find(function(m) m$type == "analysis_feature", r$sent())
    expect_identical(fb$data$values, "normalized")
    expect_false("gene03" %in% r$priv$meta_names())
    expect_s4_class(a$gobject(), "giotto")
})

test_that("a change reruns only the steps below it", {
    r <- lens_analysis_rig(cell_markers = lens_analysis_fixture()$markers,
        params = c(lens_analysis_params, list(auto_type = list(min_overlap_genes = 2))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    meta <- r$meta
    a$wait(300)
    st <- vapply(a$status, `[[`, "", "status")
    expect_true(all(st == "done"), info = paste(names(st), st, collapse = ", "))
    expect_setequal(names(r$panels()), c("qc-cells", "qc-feats", "pca-elbow"))
    expect_true(all(c("qc_pass", "umap_1", "umap_2", "leiden_clus", "cell_type",
        "cell_type_auto", "cell_type_auto_score") %in% names(meta())))
    priv <- a$.__enclos_env__$private
    n_cl <- length(unique(stats::na.omit(meta()$leiden_clus)))
    expect_identical(n_cl, 3L)
    expect_identical(nrow(priv$suggestions), n_cl)
    expect_setequal(a$labels(), c("A", "B", "C"))
    expect_match(a$code(), "runPAGEEnrich(g, sign_matrix = sign", fixed = TRUE)
    leiden_before <- a$status$leiden
    a$set("auto_type", method = "hypergeometric")
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_identical(a$status$leiden, leiden_before)
    expect_identical(nrow(meta()), 600L)

    secs <- function() vapply(a$status, function(s) s$secs %||% NA_real_, 1)
    before <- secs()
    a$set("umap", min_dist = 0.3)
    a$wait(120)
    after <- secs()
    expect_identical(after[names(after) != "umap"], before[names(before) != "umap"])

    a$set("filter", min_det_feats_per_cell = 40)
    a$wait(300)
    m <- meta()
    expect_lt(sum(m$qc_pass == "pass"), 600L)
    expect_identical(m$qc_pass == "pass", m$qc_nr_feats >= 40)
    expect_true(all(is.na(m$leiden_clus[m$qc_pass == "removed"])))

    a$set("filter", min_det_feats_per_cell = 70)
    a$wait(300)
    expect_true(all(meta()$qc_pass == "removed"))
    expect_true(all(vapply(a$status[setdiff(names(a$status), c("region", "filter"))],
        `[[`, "", "status") == "blocked"))
    expect_match(a$status$leiden$message, "QC filter")
    expect_false("leiden_clus" %in% names(meta()))
    a$set("filter", min_det_feats_per_cell = 10)
    a$wait(300)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "done"))
    expect_false(anyNA(meta()$leiden_clus))

    a$labels(c(`1` = "first"))
    a$wait(60)
    expect_true("first" %in% meta()$cell_type)
    expect_false("1" %in% names(priv$suggested))
    expect_error(a$set("leiden", resolution = -1), "at least")

    # A region: the steps run on part of the tissue
    region_ids <- utils::head(r$priv$cell_ids, 300)
    a$region(region_ids)
    a$wait(300)
    expect_identical(a$status$region$status, "done")
    expect_match(a$status$region$summary, "300 of 600")
    m <- meta()
    outside <- !m$cell_ID %in% region_ids
    expect_true(all(is.na(m$qc_pass[outside])))
    expect_true(any(!is.na(m$leiden_clus[!outside])))
    expect_match(a$code(), "subsetGiotto", fixed = TRUE)
    a$region(NULL)
    a$wait(300)
    expect_match(a$status$region$summary, "whole tissue")
    r$v$set_selection(character())
    expect_error(a$handle("analysis_region", list(action = "selection")), "select cells first")

    # Saved settings
    a$save_settings("before")
    p_saved <- a$params(); lab_saved <- a$labels()
    a$set("leiden", resolution = 0.3)
    a$wait(120)
    expect_false(identical(a$params(), p_saved))
    a$restore_settings("before")
    a$wait(120)
    expect_identical(a$params(), p_saved)
    expect_identical(a$labels(), lab_saved)
    f <- tempfile(fileext = ".json")
    a$write_settings(f)
    a$remove_settings("before")
    expect_identical(nrow(a$settings()), 0L)
    a$read_settings(f)
    expect_identical(a$settings()$name, "before")
    expect_error(a$restore_settings("nope"), "no saved settings")
})

test_that("a running step is cancelled through its job, and the analysis goes on", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    # A slow job holds the daemon, so the step's job waits behind it
    r$priv$start_job("slow", function(g) { Sys.sleep(5); 1 })
    a$set("umap", min_dist = 0.3)
    expect_true(pump_until(function() identical(a$status$umap$status, "running"), timeout = 30))
    umap_job <- function() r$v$jobs()$id[r$v$jobs()$label == "analysis: UMAP"]
    first <- umap_job()
    expect_length(first, 1L)
    a$cancel()
    expect_true(pump_until(function() !first %in% r$v$jobs()$id, timeout = 15))
    # Preprocessing runs by itself once started: the step runs again
    a$wait(120)
    expect_identical(a$status$umap$status, "done")
})

test_that("Automatic types waits for a marker list", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    expect_identical(a$status$auto_type$status, "blocked")
    expect_match(a$status$auto_type$message, "cell_markers")
    expect_identical(a$status$labels$status, "done")
    expect_false(grepl("runPAGEEnrich", a$code(), fixed = TRUE))
    a$cell_markers(data.frame(type = c("A", "A", "B", "B"),
        gene = c("gene01", "gene02", "gene11", "gene12")))
    a$set("auto_type", min_overlap_genes = 2)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "error")
    expect_match(a$status$auto_type$message, "more than 2")
    a$set("auto_type", min_overlap_genes = 1)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_true(all(stats::na.omit(r$meta()$cell_type_auto) %in% c("A", "B")))
})

test_that("Spatial interactions run only when asked", {
    r <- lens_analysis_rig(analyses = "interactions", params = c(lens_analysis_params, list(
        groups = list(column = "object:band"),
        proximity = list(number_of_simulations = 50))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("groups", "spatial_network", "proximity")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    priv <- a$.__enclos_env__$private
    expect_identical(priv$resolve_column("groups"), "object:band")
    sch <- priv$schema()
    expect_identical(vapply(sch$pipelines, `[[`, "", "id"), c("preprocess", "interactions"))
    col <- Find(function(x) x$id == "groups", sch$steps)$params[[1L]]
    expect_true(all(c("object:band", "analysis:cell_type") %in%
        vapply(col$choices, `[[`, "", "value")))

    a$run(step = "spatial_network")
    a$wait(120)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_match(a$status$groups$summary, "band")
    expect_null(r$panels()$proximity)

    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$proximity$summary, "pairs")
    spec <- r$panels()$proximity
    expect_identical(spec$mark$type, "rect")
    expect_identical(nrow(spec$data$values), 9L)
    fields <- c(spec$encoding$x$field, spec$encoding$y$field, spec$encoding$color$field,
        vapply(spec$encoding$tooltip, `[[`, "", "field"))
    expect_true(all(fields %in% names(spec$data$values)))
    expect_match(a$code("interactions"), 'cluster_column = "band", number_of_simulations = 50',
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
    expect_error(a$run("nope"), "no analysis")
})

test_that("History brings back runs; analyses are added and removed", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    expect_identical(names(a$analyses()), "preprocess")
    expect_true("interactions" %in% a$catalog()$id)
    expect_identical(nrow(a$history("preprocess")), 1L)
    expect_error(a$remove("preprocess"), "cannot be removed")

    a$handle("analysis_add", list(id = "interactions",
        params = list(groups = list(column = "object:band"),
            proximity = list(number_of_simulations = "20"))))
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
    r$v$remove_panel("proximity")
    a$restore_run("interactions", first)
    expect_identical(a$params()$spatial_network$k, 20L)
    expect_true(all(vapply(a$status[c("groups", "spatial_network", "proximity")], `[[`, "",
        "status") == "done"))
    expect_false(is.null(r$panels()$proximity))
    a$wait(30)
    expect_identical(a$history("interactions")$current, c(TRUE, FALSE))

    a$remove("interactions")
    expect_identical(names(a$analyses()), "preprocess")
    expect_null(a$status$proximity)
    expect_null(r$panels()$proximity)
    a$add("interactions")
    expect_identical(nrow(a$history("interactions")), 2L)
})

test_that("Spatial interactions follow the cell types of the Preprocessing tab", {
    r <- lens_analysis_rig(analyses = "interactions", params = c(lens_analysis_params,
        list(proximity = list(number_of_simulations = 50))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    priv <- a$.__enclos_env__$private
    st <- function() vapply(a$status[c("groups", "spatial_network", "proximity")], `[[`, "", "status")
    expect_true(all(st() == "stale"))
    expect_identical(priv$resolve_column("groups"), "analysis:cell_type")
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    a$labels(c(`1` = "first"))
    a$wait(60)
    expect_true("first" %in% r$meta()$cell_type)
    expect_true(all(st() == "stale"))
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_true(any(grepl("first", r$panels()$proximity$data$values$pair)))
})

test_that("advanced spatial network and proximity settings reach Giotto", {
    r <- lens_analysis_rig(analyses = "interactions", params = c(lens_analysis_params, list(
        groups = list(column = "object:band"),
        spatial_network = list(method = "Delaunay", maximum_distance_delaunay = 40,
            minimum_k = 1, dimensions = 1:2),
        proximity = list(number_of_simulations = 50, seed_number = 7))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    st <- function() vapply(a$status[c("groups", "spatial_network", "proximity")], `[[`, "", "status")
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$spatial_network$summary, "links")
    code <- a$code("interactions")
    expect_match(code, paste0("method = \"Delaunay\", delaunay_method = \"delaunayn_geometry\", ",
        "maximum_distance_delaunay = 40, minimum_k = 1, dimensions = 1:2"), fixed = TRUE)
    first <- a$status$spatial_network$summary
    a$set("spatial_network", method = "radius", radius = 25)
    a$set("proximity", set_seed = FALSE)
    a$run("interactions")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_false(identical(a$status$spatial_network$summary, first))
    code <- a$code("interactions")
    expect_match(code, "method = \"radius\", radius = 25", fixed = TRUE)
    expect_match(code, "set_seed = FALSE)", fixed = TRUE)
})

test_that("the Analysis panel opens in the left tray and drives the steps from the page", {
    fx <- lens_analysis_fixture()
    v <- suppressMessages(launch_lens(fx$g, feat_type = NULL, open = FALSE))
    on.exit(suppressMessages(v$close()), add = TRUE)
    br <- lens_browser(v$url, width = 1600, height = 900)
    on.exit(br$close(), add = TRUE)
    expect_true(pump_until(function() v$connected(), 30))
    priv <- get("private", v$.__enclos_env__)
    # Opened in the left tray from the tools rail, not offered by the dock's
    # "+"; opening it makes the analysis, which runs nothing
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected')"))
    br$js("[...document.querySelectorAll('.dock-add')].find(b => b.offsetParent).click()")
    expect_false(br$js("[...document.querySelectorAll('.dock-menu.open button')].some(b => b.textContent === 'analysis')"))
    br$js("document.body.click()")
    br$js("document.querySelector('[data-panel=tools] [data-act=analysis]').click()")
    expect_true(pump_until(function() !is.null(priv$lens_analysis), 30))
    expect_true(browser_wait(br, "!!document.querySelector('#drawer.open [data-panel=analysis] .an-step')", 30))
    p <- v$panels()
    expect_identical(p$group[p$id == "analysis"], "drawer")
    a <- v$analysis(params = lens_analysis_params)
    later::run_now(0.5)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "stale"))

    # A number typed on the page reaches R and runs the steps
    br$js("(() => { const s = document.querySelector('[data-step=leiden] input[data-param=resolution]');
        s.value = '0.37'; s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function() identical(a$params()$leiden$resolution, 0.37), 10))
    a$wait(300)
    expect_true(browser_wait(br,
        "document.querySelectorAll('[data-panel=analysis] .an-step.an-done').length === 10", 30))
    expect_true(browser_wait(br, "window.__giottolens.store.getState().colorBy === 'leiden_clus'", 30))
    # Its steps showed as jobs
    expect_true(browser_wait(br, "[...document.querySelectorAll('.jobs-badge')].length > 0"))

    # A change from R shows in the page's menu
    a$set("umap", min_dist = 0.3)
    expect_true(browser_wait(br,
        "document.querySelector('[data-step=umap] input[data-param=min_dist]').value === '0.3'", 30))
    a$wait(120)

    # Closed from R, the left tray goes; its width drags from its right edge
    # and stays after a reload, open again
    v$remove_panel("analysis")
    expect_true(browser_wait(br, "!document.querySelector('#drawer.open')"))
    expect_false("analysis" %in% v$panels()$id)
    br$js("document.querySelector('[data-panel=tools] [data-act=analysis]').click()")
    expect_true(browser_wait(br, "!!document.querySelector('#drawer.open')"))
    expect_equal(br$js("document.getElementById('drawer').getBoundingClientRect().width"), 360, tolerance = 2)
    e <- br$js("(() => { const r = document.querySelector('#drawer .drawer-sash').getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()")
    send <- function(type, x) br$session$Input$dispatchMouseEvent(type = type, x = x, y = e[[2]], button = "left",
        buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mousePressed", e[[1]]); send("mouseMoved", e[[1]] + 40); send("mouseMoved", e[[1]] + 100); send("mouseReleased", e[[1]] + 100)
    expect_true(pump_until(function() grepl('"drawerWidth":4', priv$config_json %||% "", fixed = TRUE), 10))
    br$js("location.reload()")
    Sys.sleep(0.3)
    expect_true(browser_wait(br, "!!document.querySelector('.r-status.connected') && !!document.querySelector('#drawer.open [data-panel=analysis]')", 30))
    expect_equal(br$js("document.getElementById('drawer').getBoundingClientRect().width"), 460, tolerance = 3)
    expect_length(br$errors(), 0L)
})
