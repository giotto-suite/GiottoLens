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
        '"normalized", spatial_network_name = "lens_spatial")'))
    code <- st$code(list(method = "binspect_rank", feats = "hvf", percentage_rank = 20),
        list(normalize = list(scale = TRUE)))
    expect_match(code, 'feats <- fDataDT(g)[hvf == "yes", feat_ID]\n', fixed = TRUE)
    expect_match(code, 'bin_method = "rank", expression_values = "scaled", subset_feats = feats',
        fixed = TRUE)
    expect_match(code, "percentage_rank = 20)", fixed = TRUE)
    code <- st$code(list(method = "geary", feats = "all", percentage_rank = 30), list())
    expect_identical(code, paste0('sg <- spatialAutoCor(g, method = "geary", expression_values = ',
        '"normalized", spatial_network_name = "lens_spatial", return_gobject = FALSE)'))
    code <- st$code(list(method = "silhouette", feats = "hvf", percentage_rank = 30), list())
    expect_match(code, 'silhouetteRank(g, expression_values = "normalized", subset_genes = feats)',
        fixed = TRUE)
    p <- .analysis_entry_spatial_genes()$steps$sg_genes$params
    expect_identical(vapply(p, `[[`, "", "default"), c("binspect_kmeans", "all", "30"))
})

test_that("Co-expression code follows the gene selection and modules", {
    st <- .analysis_entry_coexpression()$steps
    expect_identical(st$cm_genes$code(list(padj = 0.05, n = 80L), list()),
        paste0('g <- spatialAutoCor(g, method = "binspect", bin_method = "kmeans", ',
            'expression_values = "normalized", spatial_network_name = "lens_spatial")'))
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

    st <- .analysis_entry_coexpression()$steps$cm_modules
    heat <- data.frame(module_a = rep(c("M1", "M2"), 2), module_b = rep(c("M1", "M2"), each = 2),
        cor = c(1, 0.2, 0.2, 1))
    out <- st$view(list(heat = heat, order = c("M1", "M2"),
        genes = data.frame(gene = c("A", "B"), module = 1:2, module_cor = c(0.5, 0.6),
            binspect_z = c(10, 9)),
        modules = data.frame(module = 1:2, genes = c(1L, 1L), mean_module_cor = c(0.5, 0.6),
            top_genes = c("A", "B"))), list())
    expect_identical(vapply(out$tables, `[[`, "", "id"), c("cm_module_genes", "cm_module_summary"))
    expect_identical(out$tables[[1L]]$feat, "gene")
    spec <- out$panels[[1L]]$spec
    expect_identical(out$panels[[1L]]$id, "cm_heatmap")
    fields <- c(spec$encoding$x$field, spec$encoding$y$field, spec$encoding$color$field)
    expect_true(all(fields %in% names(spec$data$values)))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
})

# The steps on the 400 um MERSCOPE vault, against a stand-in viewer
mini_vault <- "/Users/jeffreysheridan/Documents/Projects/GiottoDev/vaults/render_mini_20261103/giotto_project"

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

test_that("Spatial genes run on the mini vault", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "spatial_genes", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        sg_genes = list(feats = "hvf")))
    on.exit(a$close(), add = TRUE)
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
    expect_false(grepl("no hvf column", a$status$sg_genes$summary))
    priv <- a$.__enclos_env__$private
    tab <- priv$tables$sg_genes[[1L]]
    expect_identical(tab$id, "sg_gene_table")
    expect_identical(tab$feat, "gene")
    expect_true(all(c("gene", "score", "p_value", "adj_p_value") %in% unlist(tab$columns)))
    expect_gt(tab$n, 0L)
    expect_identical(v$panels$sg_top$mark$type, "bar")
    expect_identical(nrow(a$history("spatial_genes")), 1L)
    expect_match(a$code("spatial_genes"), "subset_feats = feats", fixed = TRUE)

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

test_that("Co-expression modules run on the mini vault", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "coexpression", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        cm_source = list(from = "object"),
        cm_modules = list(n_modules = 6)))
    on.exit(a$close(), add = TRUE)
    ist <- c("cm_source", "cm_network", "cm_genes", "cm_modules")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("coexpression")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$cm_genes$summary, "genes with adj. p < 0.05; 80 used", fixed = TRUE)
    expect_match(a$status$cm_modules$summary, "80 genes in 6 modules", fixed = TRUE)
    expect_true(all(paste0("cm_module_", 1:6) %in% names(v$meta)))
    expect_false(all(is.na(v$meta$cm_module_1)))
    priv <- a$.__enclos_env__$private
    tabs <- priv$tables$cm_modules
    expect_identical(vapply(tabs, `[[`, "", "id"), c("cm_module_genes", "cm_module_summary"))
    expect_identical(tabs[[1L]]$feat, "gene")
    expect_identical(tabs[[1L]]$n, 80L)
    spec <- v$panels$cm_heatmap
    expect_identical(spec$mark$type, "rect")
    expect_identical(nrow(spec$data$values), 36L)
    expect_identical(nrow(a$history("coexpression")), 1L)
    expect_match(a$code("coexpression"), "n_modules = 6", fixed = TRUE)

    a$set("cm_modules", n_modules = 4)
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "done", "stale"))
    a$set("cm_genes", n = 40)
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale", "stale"))
    expect_identical(nrow(a$history("coexpression")), 1L)
})
