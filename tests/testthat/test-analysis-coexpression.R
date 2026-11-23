test_that("Co-expression advanced settings have Giotto's defaults and reach the code", {
    st <- .analysis_catalog()$coexpression$steps
    expect_identical(.adv_ids(st$cm_genes), c("bin_method", "percentage_rank", "null",
        "covariate", "n_groups", "weighted", "adjust_method"))
    expect_identical(.adv_ids(st$cm_modules), c("hops", "weighted", "cluster_method"))
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

test_that("Co-expression views build tables and panels", {
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

test_that("Co-expression modules run", {
    r <- lens_analysis_rig(analyses = "coexpression", params = c(lens_analysis_params, list(
        cm_source = list(from = "object"),
        cm_genes = list(n = 30),
        cm_modules = list(n_modules = 6))), network_dir = NULL)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("cm_source", "cm_network", "cm_genes", "cm_modules")
    st <- function() step_status(a, ist)
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
    st <- function() step_status(a, ist)
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
