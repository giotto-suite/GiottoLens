# ── Parameters and generated code ───────────────────────────────────────────

test_that("Spatial genes code follows the method and gene set", {
    st <- .analysis_entry_spatial_genes()$steps$sg_genes
    code <- st$code(list(method = "binspect_kmeans", feats = "all", percentage_rank = 30), list())
    expect_identical(code, paste0('sg <- binSpect(g, bin_method = "kmeans", expression_values = ',
        '"normalized", spatial_network_name = "spatial_network")'))
    code <- st$code(list(method = "binspect_rank", feats = "hvf", percentage_rank = 20),
        list(sg_source = list(expression_values = "scaled")))
    expect_match(code, 'feats <- fDataDT(g)[hvf == "yes", feat_ID]\n', fixed = TRUE)
    expect_match(code, 'bin_method = "rank", expression_values = "scaled", subset_feats = feats',
        fixed = TRUE)
    expect_match(code, "percentage_rank = 20)", fixed = TRUE)
    code <- st$code(list(method = "geary", feats = "all", percentage_rank = 30), list())
    expect_identical(code, paste0('sg <- spatialAutoCor(g, method = "geary", expression_values = ',
        '"normalized", spatial_network_name = "spatial_network", return_gobject = FALSE)'))
    code <- st$code(list(method = "silhouette", feats = "hvf", percentage_rank = 30), list())
    expect_match(code, 'silhouetteRank(g, expression_values = "normalized", subset_genes = feats)',
        fixed = TRUE)
    p <- .analysis_entry_spatial_genes()$steps$sg_genes$params
    basic <- Filter(function(q) !isTRUE(q$advanced), p)
    expect_identical(vapply(basic, `[[`, "", "default"), c("binspect_kmeans", "all", "30"))
})

test_that("Spatial genes advanced settings have Giotto's defaults", {
    st <- .analysis_catalog()$spatial_genes$steps$sg_genes
    ids <- .adv_ids(st)
    expect_identical(ids, c("adjust_method", "implementation", "do_fisher_test", "kmeans_algo",
        "nstart", "iter_max", "extreme_nr", "sample_nr", "seed", "reduce_network", "calc_hub",
        "hub_min_int", "get_av_expr", "get_high_expr", "group_size", "spatial_network_k",
        "summarize", "null", "covariate", "n_groups", "weighted", "metric", "rbp_p",
        "examine_top"))
    p <- .default_p(st)
    expect_identical(p$adjust_method, "fdr")
    expect_identical(p$implementation, "fast")
    expect_true(p$do_fisher_test)
    expect_false(p$calc_hub)
    expect_identical(p$nstart, 3L)
    expect_identical(p$iter_max, 10L)
    expect_identical(p$seed, 1234L)
    expect_null(p$group_size)
    expect_identical(p$spatial_network_k, "")
    expect_identical(p$null, "permutation")
    expect_identical(p$covariate, "libsize")
    expect_identical(p$n_groups, 10L)
    expect_identical(p$metric, "euclidean")
    expect_identical(p$rbp_p, 0.95)
    expect_identical(p$examine_top, 0.3)
    for (m in c("binspect_kmeans", "binspect_rank", "moran", "geary", "silhouette")) {
        p$method <- m
        expect_false(grepl("adjust_method|implementation|seed|null|weighted|metric|rbp_p",
            st$code(p, list())), info = m)
    }
    imp <- .par(st, "implementation")
    expect_identical(vapply(.offered(imp$choices, TRUE), `[[`, "", "value"), "fast")
    expect_identical(length(.offered(imp$choices, FALSE)), 4L)
    vals <- lapply(.default_p(st), function(v) if (is.null(v)) "auto" else as.character(v))
    shown <- function(id, v) .param_shown(.par(st, id), v)
    expect_false(shown("nstart", vals))
    expect_false(shown("calc_hub", vals))
    vals$implementation <- "data.table"
    expect_true(shown("nstart", vals))
    expect_true(shown("group_size", vals))
    expect_false(shown("hub_min_int", vals))
    expect_false(shown("extreme_nr", vals))
    vals$kmeans_algo <- "kmeans_arma_subset"
    expect_true(shown("extreme_nr", vals))
    vals$method <- "binspect_rank"
    expect_false(shown("nstart", vals))
    expect_false(shown("seed", vals))
    vals$method <- "moran"
    expect_false(shown("implementation", vals))
    expect_true(shown("null", vals))
    expect_false(shown("covariate", vals))
    vals$null <- "covariate"
    expect_true(shown("covariate", vals))
    vals$method <- "geary"
    expect_false(shown("null", vals))
    expect_true(shown("weighted", vals))
})

test_that("Spatial genes code includes advanced values that differ from the default", {
    st <- .analysis_catalog()$spatial_genes$steps$sg_genes
    p <- .default_p(st)
    p$adjust_method <- "bonferroni"
    expect_identical(st$code(p, list()), paste0('sg <- binSpect(g, bin_method = "kmeans", ',
        'expression_values = "normalized", spatial_network_name = "spatial_network", ',
        'adjust_method = "bonferroni")'))
    p$nstart <- 5L
    expect_false(grepl("nstart", st$code(p, list())))
    p$implementation <- "data.table"
    p["seed"] <- list(NULL)
    p$calc_hub <- TRUE
    p$hub_min_int <- 2L
    p$group_size <- 20L
    p$spatial_network_k <- "5, 10"
    code <- st$code(p, list())
    expect_match(code, paste0('adjust_method = "bonferroni", implementation = "data.table", ',
        'calc_hub = TRUE, hub_min_int = 2, group_size = 20, spatial_network_k = c(5, 10), ',
        'nstart = 5, seed = NULL)'), fixed = TRUE)
    p$method <- "binspect_rank"
    expect_false(grepl("nstart|seed", st$code(p, list())))
    p <- .default_p(st)
    p$method <- "moran"
    p$null <- "covariate"
    p$covariate <- "leiden_clus"
    p$n_groups <- 5L
    p$weighted <- TRUE
    expect_identical(st$code(p, list()), paste0('sg <- spatialAutoCor(g, method = "moran", ',
        'expression_values = "normalized", spatial_network_name = "spatial_network", ',
        'null = "covariate", covariate = "leiden_clus", n_groups = 5, weighted = TRUE, ',
        'return_gobject = FALSE)'))
    p$method <- "geary"
    expect_identical(st$code(p, list()), paste0('sg <- spatialAutoCor(g, method = "geary", ',
        'expression_values = "normalized", spatial_network_name = "spatial_network", ',
        'weighted = TRUE, return_gobject = FALSE)'))
    p <- .default_p(st)
    p$method <- "silhouette"
    p$metric <- "cityblock"
    p$rbp_p <- 0.9
    p$examine_top <- 0.2
    expect_identical(st$code(p, list()), paste0('sg <- silhouetteRank(g, expression_values = ',
        '"normalized", metric = "cityblock", rbp_p = 0.9, examine_top = 0.2)'))
})

test_that("advanced values reach the Giotto calls", {
    skip_if_not_installed("Giotto")
    got <- NULL
    capture <- function(...) {
        got <<- list(...)[-1L]
        data.frame(feats = c("A", "B"), z = c(2, 1), p.value = c(0.01, 0.2),
            adj.p.value = c(0.02, 0.2))
    }
    local_mocked_bindings(binSpect = capture, spatialAutoCor = capture,
        silhouetteRank = capture, .package = "Giotto")
    local_mocked_bindings(fDataDT = function(g) data.frame(feat_ID = c("A", "B")),
        .package = "GiottoClass")
    st <- .analysis_catalog()$spatial_genes$steps$sg_genes
    res <- st$result
    environment(res) <- list2env(list(.lens_values = function(p) "normalized",
        .lens_net = function(p) "spatial_network",
        .lens_threads = function() 2L), parent = globalenv())
    p <- .default_p(st)
    p$implementation <- "data.table"
    p$do_fisher_test <- FALSE
    p$kmeans_algo <- "kmeans_arma_subset"
    p$nstart <- 5L
    p$iter_max <- 20L
    p$extreme_nr <- 30L
    p$sample_nr <- 60L
    p["seed"] <- list(NULL)
    p$reduce_network <- TRUE
    p$calc_hub <- TRUE
    p$hub_min_int <- 2L
    p$get_av_expr <- FALSE
    p$get_high_expr <- FALSE
    p$group_size <- 20L
    p$spatial_network_k <- "5, 10"
    p$summarize <- "adj.p.value"
    p$adjust_method <- "BY"
    res(NULL, p, NULL)
    want <- list(bin_method = "kmeans", adjust_method = "BY", implementation = "data.table",
        do_fisher_test = FALSE, reduce_network = TRUE, calc_hub = TRUE, get_av_expr = FALSE,
        get_high_expr = FALSE, cores = 2L, hub_min_int = 2L, group_size = 20L,
        spatial_network_k = c(5, 10), summarize = "adj.p.value", kmeans_algo = "kmeans_arma_subset",
        nstart = 5L, iter_max = 20L, extreme_nr = 30L, sample_nr = 60L)
    for (k in names(want)) expect_identical(got[[k]], want[[k]], info = k)
    expect_true("seed" %in% names(got))
    expect_null(got$seed)
    p$implementation <- "fast"
    res(NULL, p, NULL)
    expect_false(any(c("nstart", "seed", "calc_hub", "cores") %in% names(got)))
    expect_identical(got$adjust_method, "BY")

    p <- .default_p(st)
    p$method <- "moran"
    p$null <- "covariate"
    p$covariate <- " "
    p$n_groups <- 4L
    p$weighted <- TRUE
    p$adjust_method <- "holm"
    res(NULL, p, NULL)
    expect_identical(got[c("method", "null", "covariate", "n_groups", "weighted", "adjust_method")],
        list(method = "moran", null = "covariate", covariate = "libsize", n_groups = 4L,
            weighted = TRUE, adjust_method = "holm"))
    p$method <- "geary"
    res(NULL, p, NULL)
    expect_false(any(c("null", "covariate", "n_groups") %in% names(got)))
    expect_true(got$weighted)

    p <- .default_p(st)
    p$method <- "silhouette"
    p$metric <- "cityblock"
    p$rbp_p <- 0.9
    p$examine_top <- 0.2
    res(NULL, p, NULL)
    expect_identical(got[c("metric", "rbp_p", "examine_top")],
        list(metric = "cityblock", rbp_p = 0.9, examine_top = 0.2))

    cm <- .analysis_catalog()$coexpression$steps
    run <- cm$cm_genes$run
    environment(run) <- environment(res)
    p <- .default_p(cm$cm_genes)
    p$bin_method <- "rank"
    p$percentage_rank <- 20
    p$null <- "covariate"
    p$covariate <- "cell_type"
    p$n_groups <- 5L
    p$weighted <- TRUE
    p$adjust_method <- "none"
    run(NULL, p)
    expect_identical(got[c("method", "bin_method", "null", "weighted", "adjust_method",
        "percentage_rank", "covariate", "n_groups")], list(method = "binspect",
        bin_method = "rank", null = "covariate", weighted = FALSE, adjust_method = "none",
        percentage_rank = 20, covariate = "cell_type", n_groups = 5L))
    expect_false(grepl("weighted", cm$cm_genes$code(p, list())))
    p$null <- "permutation"
    run(NULL, p)
    expect_true(got$weighted)
    expect_match(cm$cm_genes$code(p, list()), "weighted = TRUE", fixed = TRUE)

    p <- .default_p(st)
    p$implementation <- "matrix"
    p$do_fisher_test <- FALSE
    p$calc_hub <- TRUE
    res(NULL, p, NULL)
    expect_false(any(c("do_fisher_test", "calc_hub", "group_size") %in% names(got)))
    expect_identical(st$code(p, list()), paste0('sg <- binSpect(g, bin_method = "kmeans", ',
        'expression_values = "normalized", spatial_network_name = "spatial_network", ',
        'implementation = "matrix")'))
})

test_that("Spatial genes views build tables and panels", {
    st <- .analysis_entry_spatial_genes()$steps$sg_genes
    genes <- data.frame(rank = 1:3, gene = c("A", "B", "C"), score = c(5, 3, 1),
        p_value = c(0, 0.01, 0.5), adj_p_value = c(0, 0.02, 0.5))
    out <- st$view(list(genes = genes, method = "Moran's I"), list())
    expect_identical(out$tables[[1L]]$id, "sg_gene_table")
    expect_identical(out$tables[[1L]]$feat, "gene")
    expect_identical(out$panels[[1L]]$id, "sg_top")
    expect_identical(out$panels[[1L]]$spec$mark$type, "bar")

    expect_identical(out$panels[[1L]]$spec$params[[1L]]$name, "pick")
    expect_identical(st$pick(list(gene = list("B")), list(), list()), list(feature = "B"))
})

# ── Runs ────────────────────────────────────────────────────────────────────

test_that("Spatial genes run, then run again with advanced settings", {
    r <- lens_analysis_rig(analyses = "spatial_genes", params = c(lens_analysis_params, list(
        sg_genes = list(feats = "all"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("sg_source", "sg_network", "sg_genes")
    st <- function() step_status(a, ist)
    a$wait(300)
    expect_true(all(st() == "stale"))
    expect_identical(nrow(a$history("spatial_genes")), 0L)
    expect_error(a$set("sg_genes", implementation = "data.table"), "must be one of: fast")

    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sg_genes$summary, "genes with adj. p < 0.05 (binSpect kmeans)",
        fixed = TRUE)
    priv <- a$.__enclos_env__$private
    tab <- priv$tables$sg_genes[[1L]]
    expect_identical(tab$id, "sg_gene_table")
    expect_identical(tab$feat, "gene")
    expect_true(all(c("gene", "score", "p_value", "adj_p_value") %in% unlist(tab$columns)))
    expect_gt(tab$n, 0L)
    expect_identical(r$panels()$sg_top$mark$type, "bar")
    expect_identical(nrow(a$history("spatial_genes")), 1L)

    a$set("sg_genes", method = "binspect_rank", percentage_rank = 20,
        adjust_method = "bonferroni")
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_identical(nrow(a$history("spatial_genes")), 1L)
    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sg_genes$summary, "(binSpect rank)", fixed = TRUE)
    expect_match(a$code("spatial_genes"), 'percentage_rank = 20, adjust_method = "bonferroni")',
        fixed = TRUE)
    expect_identical(nrow(a$history("spatial_genes")), 2L)
    n_rank <- as.integer(sub(" of.*", "", a$status$sg_genes$summary))

    a$set("sg_genes", method = "moran", null = "covariate", covariate = "band",
        weighted = TRUE, adjust_method = "BY")
    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sg_genes$summary, "Moran's I", fixed = TRUE)
    expect_match(a$code("spatial_genes"), paste0('null = "covariate", covariate = "band", ',
        'weighted = TRUE, adjust_method = "BY", return_gobject = FALSE)'), fixed = TRUE)

    a$set("sg_genes", covariate = "libsize", n_groups = 4, weighted = FALSE)
    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$code("spatial_genes"), 'null = "covariate", n_groups = 4, adjust_method = "BY"',
        fixed = TRUE)
    tab <- priv$tables$sg_genes[[1L]]
    expect_gt(tab$n, 0L)
    expect_true(is.finite(n_rank))

    a$set("sg_network", k = 10)
    a$wait(10)
    expect_identical(unname(st()), c("done", "stale", "stale"))
})
