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

# The R values of a step's defaults
.default_p <- function(st) {
    p <- list()
    for (par in st$params) p[par$id] <- list(.param_r(par, par$default))
    p
}

test_that("Spatial genes advanced settings have Giotto's defaults", {
    st <- .analysis_catalog()$spatial_genes$steps$sg_genes
    adv <- Filter(function(q) isTRUE(q$advanced), st$params)
    ids <- vapply(adv, `[[`, "", "id")
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
    imp <- Find(function(q) q$id == "implementation", st$params)
    expect_identical(vapply(.offered(imp$choices, TRUE), `[[`, "", "value"), "fast")
    expect_identical(length(.offered(imp$choices, FALSE)), 4L)
    vals <- lapply(.default_p(st), function(v) if (is.null(v)) "auto" else as.character(v))
    shown <- function(id, v) .param_shown(Find(function(q) q$id == id, st$params), v)
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

test_that("Co-expression advanced settings have Giotto's defaults and reach the code", {
    st <- .analysis_catalog()$coexpression$steps
    adv <- function(s) vapply(Filter(function(q) isTRUE(q$advanced), st[[s]]$params),
        `[[`, "", "id")
    expect_identical(adv("cm_genes"), c("bin_method", "percentage_rank", "null", "covariate",
        "n_groups", "weighted", "adjust_method"))
    expect_identical(adv("cm_modules"), c("hops", "weighted", "cluster_method"))
    g <- .default_p(st$cm_genes)
    m <- .default_p(st$cm_modules)
    expect_identical(m$hops, 1L)
    expect_identical(m$cluster_method, "ward.D")
    expect_false(m$weighted)
    expect_identical(st$cm_genes$code(g, list()),
        paste0('g <- spatialAutoCor(g, method = "binspect", bin_method = "kmeans", ',
            'expression_values = "normalized", spatial_network_name = "spatial_network")'))
    expect_false(grepl("hops|weighted|cluster_method",
        st$cm_modules$code(m, list(cm_genes = g))))
    g$bin_method <- "rank"
    g$percentage_rank <- 20
    g$null <- "covariate"
    g$adjust_method <- "BH"
    expect_identical(st$cm_genes$code(g, list()),
        paste0('g <- spatialAutoCor(g, method = "binspect", bin_method = "rank", ',
            'expression_values = "normalized", spatial_network_name = "spatial_network", ',
            'percentage_rank = 20, null = "covariate", adjust_method = "BH")'))
    m$hops <- 2L
    m$weighted <- TRUE
    m$cluster_method <- "average"
    expect_match(st$cm_modules$code(m, list(cm_genes = g)),
        'score_stat = "mean", weighted = TRUE, hops = 2, cluster_method = "average", ',
        fixed = TRUE)
})

test_that("Co-expression code follows the gene selection and modules", {
    st <- .analysis_entry_coexpression()$steps
    expect_identical(st$cm_genes$code(list(padj = 0.05, n = 80L), list()),
        paste0('g <- spatialAutoCor(g, method = "binspect", bin_method = "kmeans", ',
            'expression_values = "normalized", spatial_network_name = "spatial_network")'))
    code <- st$cm_modules$code(list(n_modules = 6L, smoothing = NULL, cor_method = "pearson",
        score_stat = "mean"), list(cm_genes = list(padj = 0.01, n = 50L)))
    expect_match(code, "fm <- fDataDT(g)[binspect.padj < 0.01][order(-binspect.z)]", fixed = TRUE)
    expect_match(code, 'feats = head(fm$feat_ID, 50), cor_method = "pearson", n_modules = 6',
        fixed = TRUE)
    expect_match(code, 'name = "cm_module")', fixed = TRUE)
    expect_match(code, "cell_annotation_values = as.character(1:6))", fixed = TRUE)
    code <- st$cm_modules$code(list(n_modules = 6L, smoothing = 0.5, cor_method = "spearman",
        score_stat = "zmean"), list(cm_genes = list(padj = 0.05, n = 80L)))
    expect_match(code, 'smoothing = 0.5, cor_method = "spearman"', fixed = TRUE)
    expect_match(code, 'score_stat = "zmean"', fixed = TRUE)
    code <- st$cm_modules$code(list(n_modules = NULL, k_max = 12L, smoothing = NULL,
        cor_method = "pearson", score_stat = "mean"), list(cm_genes = list(padj = 0.05, n = 80L)))
    expect_match(code, "return_gobject = FALSE)", fixed = TRUE)
    expect_match(code, "ks <- 2:min(12, nrow(r) - 1)", fixed = TRUE)
    expect_match(code, "n_modules = n_modules,", fixed = TRUE)
    expect_match(code, "cell_annotation_values = as.character(1:n_modules))", fixed = TRUE)
    expect_silent(parse(text = code))
    d <- .default_values(.analysis_entry_coexpression()$steps, disk = TRUE)$cm_modules
    expect_identical(d[c("n_modules", "k_max")], list(n_modules = "auto", k_max = "15"))
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

test_that("Spatial genes and co-expression views build tables and panels", {
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

    st <- .analysis_entry_coexpression()$steps$cm_modules
    heat <- data.frame(gene_a = rep(c("A", "B"), 2), gene_b = rep(c("A", "B"), each = 2),
        cor = c(1, 0.2, 0.2, 1), module = rep(1:2, 2))
    out <- st$view(list(heat = heat, order = c("A", "B"),
        k_scores = data.frame(k = 2:4, silhouette = c(0.2, 0.5, 0.3)),
        genes = data.frame(gene = c("A", "B"), module = 1:2, module_cor = c(0.5, 0.6),
            binspect_z = c(10, 9)),
        modules = data.frame(module = 1:2, genes = c(1L, 1L), mean_module_cor = c(0.5, 0.6),
            top_genes = c("A", "B"))), list())
    expect_identical(vapply(out$tables, `[[`, "", "id"), c("cm_module_genes", "cm_module_summary"))
    expect_identical(out$tables[[1L]]$feat, "gene")
    expect_identical(vapply(out$panels, `[[`, "", "id"), c("cm_heatmap", "cm_k"))
    spec <- out$panels[[1L]]$spec
    expect_true(all(vapply(spec$layer, function(l) is.null(l$data), NA)))
    for (ly in spec$layer) {
        fields <- c(ly$encoding$x$field, ly$encoding$y$field, ly$encoding$color$field)
        expect_true(all(fields %in% names(spec$data$values)))
        expect_false(any(grepl(".", fields, fixed = TRUE)))
    }
    expect_identical(spec$layer[[1L]]$params[[1L]]$name, "pick")
    rows <- spec$data$values
    expect_identical(rows$gene_a[rows$row == "module"], c("A", "B"))
    expect_identical(rows$module[rows$row == "module"], c("M1", "M2"))
    box <- rows[rows$row == "box", ]
    expect_identical(box$module, c("M1", "M2"))
    expect_identical(as.numeric(box$x1 - box$x0), c(1, 1))
    expect_identical(spec$layer[[3L]]$encoding$stroke$scale, spec$layer[[2L]]$encoding$color$scale)
    expect_identical(st$pick(list(module = list("M2")), list(), list()),
        list(color = "cm_module_2"))
    expect_null(st$pick(list(gene_a = list("A")), list(), list()))
    expect_identical(spec$layer[[1L]]$params[[2L]]$name, "range")
    expect_identical(spec$layer[[1L]]$params[[2L]]$select$encodings, list("x", "y"))
    res <- list(order = c("B", "A", "C", "D"),
        heat = data.frame(gene_a = c("A", "B", "C", "D")))
    expect_identical(st$pick(list(range = list(x0 = list(0.2, 1.7))), res, list()),
        list(genes = c("B", "A")))
    expect_identical(st$pick(list(range = list(x0 = list(0.2, 0.8), y0 = list(3.7, 2.2))),
        res, list()), list(genes = c("B", "C", "D")))
    expect_identical(st$pick(list(range = list(x0 = list(0.2, 0.8), y0 = list(-1.3, -0.5))),
        res, list()), list(genes = "B"))
    expect_identical(st$pick(list(range = list(x0 = list(3.9, 3.6))), res, list()),
        list(genes = character()))
    k <- out$panels[[2L]]$spec
    expect_identical(k$data$values$best, c(FALSE, TRUE, FALSE))
    expect_identical(k$data$values$used, c(FALSE, TRUE, FALSE))
    expect_identical(k$layer[[4L]]$params[[1L]]$name, "pick")
    expect_identical(st$pick(list(k = list(4)), list(), list()), list(set = list(n_modules = 4L)))
    k <- .k_scores_spec(data.frame(k = 2:4, silhouette = c(0.2, 0.5, 0.3),
        used = c(FALSE, FALSE, TRUE)), "niches")
    expect_identical(k$data$values$status, c("", "highest score", "in use"))
    expect_identical(.analysis_entry_niches()$steps$nc_kmeans$pick(list(k = list(3)), list(),
        list()), list(set = list(k = 3L)))
})

test_that("Spatial genes run", {
    r <- lens_analysis_rig(analyses = "spatial_genes", params = c(lens_analysis_params, list(
        sg_genes = list(feats = "all"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("sg_source", "sg_network", "sg_genes")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    expect_identical(nrow(a$history("spatial_genes")), 0L)

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

    a$set("sg_genes", method = "moran")
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_identical(nrow(a$history("spatial_genes")), 1L)
    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sg_genes$summary, "Moran's I", fixed = TRUE)
    expect_identical(nrow(a$history("spatial_genes")), 2L)

    a$set("sg_network", k = 10)
    a$wait(10)
    expect_identical(unname(st()), c("done", "stale", "stale"))
})

test_that("Spatial genes advanced settings run", {
    r <- lens_analysis_rig(analyses = "spatial_genes", params = c(lens_analysis_params, list(
        sg_source = list(from = "object"),
        sg_genes = list(method = "binspect_rank", percentage_rank = 20,
            adjust_method = "bonferroni"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("sg_source", "sg_network", "sg_genes")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    expect_error(a$set("sg_genes", implementation = "data.table"), "must be one of: fast")
    a$run("spatial_genes")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sg_genes$summary, "(binSpect rank)", fixed = TRUE)
    expect_match(a$code("spatial_genes"), 'percentage_rank = 20, adjust_method = "bonferroni")',
        fixed = TRUE)
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
    tab <- a$.__enclos_env__$private$tables$sg_genes[[1L]]
    expect_gt(tab$n, 0L)
    expect_true(is.finite(n_rank))
})

test_that("Co-expression modules run", {
    r <- lens_analysis_rig(analyses = "coexpression", params = c(lens_analysis_params, list(
        cm_source = list(from = "object"),
        cm_genes = list(n = 30),
        cm_modules = list(n_modules = 6))), network_dir = NULL)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("cm_source", "cm_network", "cm_genes", "cm_modules")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("coexpression")
    a$wait(300)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$cm_genes$summary, "genes with adj. p < 0.05; 30 used", fixed = TRUE)
    expect_match(a$status$cm_modules$summary, "30 genes in 6 modules", fixed = TRUE)
    m <- r$meta()
    expect_true(all(paste0("cm_module_", 1:6) %in% names(m)))
    expect_false(all(is.na(m$cm_module_1)))
    priv <- a$.__enclos_env__$private
    tabs <- priv$tables$cm_modules
    expect_identical(vapply(tabs, `[[`, "", "id"), c("cm_module_genes", "cm_module_summary"))
    expect_identical(tabs[[1L]]$feat, "gene")
    expect_identical(tabs[[1L]]$n, 30L)
    spec <- r$panels()$cm_heatmap
    expect_identical(spec$layer[[1L]]$mark$type, "rect")
    expect_identical(sum(spec$data$values$row == "cor"), 900L)
    expect_identical(sort(unique(spec$data$values$module[spec$data$values$row == "module"])),
        paste0("M", 1:6))
    expect_identical(nrow(a$history("coexpression")), 1L)
    expect_match(a$code("coexpression"), "n_modules = 6", fixed = TRUE)

    a$set("cm_modules", n_modules = 4)
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "done", "stale"))
    a$set("cm_genes", n = 20)
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale", "stale"))
    expect_identical(nrow(a$history("coexpression")), 1L)
})

test_that("Co-expression advanced settings run", {
    r <- lens_analysis_rig(analyses = "coexpression", params = c(lens_analysis_params, list(
        cm_source = list(from = "object"),
        cm_genes = list(bin_method = "rank", percentage_rank = 20, null = "covariate",
            covariate = "libsize", n_groups = 4, adjust_method = "BH", n = 20),
        cm_modules = list(n_modules = 4, hops = 2, weighted = TRUE,
            cluster_method = "average"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("cm_source", "cm_network", "cm_genes", "cm_modules")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$run("coexpression")
    a$wait(300)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$cm_genes$summary, "; 20 used", fixed = TRUE)
    expect_match(a$status$cm_modules$summary, "20 genes in 4 modules", fixed = TRUE)
    code <- a$code("coexpression")
    # The loaded object has raw values only
    expect_match(code, paste0('bin_method = "rank", expression_values = "raw", ',
        'spatial_network_name = "kNN_network", percentage_rank = 20, null = "covariate", ',
        'n_groups = 4, adjust_method = "BH")'), fixed = TRUE)
    expect_match(code, 'weighted = TRUE, hops = 2, cluster_method = "average"', fixed = TRUE)
})
