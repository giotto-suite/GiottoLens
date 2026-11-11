# Markers between groups, Subclustering and Cluster tree

test_that("cluster entries have their fields, prefixed steps and order", {
    cat <- .analysis_catalog()
    want <- list(markers_groups = c("mg_", 60), subcluster = c("sc_", 70),
        cluster_tree = c("ct_", 80))
    for (k in names(want)) {
        e <- cat[[k]]
        expect_false(is.null(e), info = k)
        expect_identical(e$id, k)
        expect_identical(e$order, as.numeric(want[[k]][[2L]]))
        expect_false(e$auto)
        expect_true(all(startsWith(names(e$steps), want[[k]][[1L]])), info = k)
        expect_identical(e$steps[[1L]]$kind, "source")
        expect_null(e$steps[[1L]]$input)
        for (s in names(e$steps)) expect_true(is.function(e$steps[[s]]$code), info = s)
        expect_true(length(e$inputs) > 0L && length(e$outputs) > 0L)
    }
    expect_identical(names(cat$markers_groups$steps), c("mg_source", "mg_groups", "mg_markers"))
    expect_identical(cat$markers_groups$steps$mg_groups$kind, "groups")
    expect_identical(names(cat$subcluster$steps), c("sc_source", "sc_subcluster"))
    expect_identical(names(cat$cluster_tree$steps),
        c("ct_source", "ct_groups", "ct_tree", "ct_markers"))
    expect_identical(cat$cluster_tree$steps$ct_groups$params[[1L]]$default, "leiden_clus")
    types <- function(st) vapply(st$params, `[[`, "", "type")
    mp <- cat$markers_groups$steps$mg_markers
    expect_identical(unname(types(mp)[vapply(mp$params, `[[`, "", "id") %in%
        c("group_1", "group_2")]), c("text", "text"))
    sp <- cat$subcluster$steps$sc_subcluster
    expect_identical(Find(function(x) x$id == "selected_clusters", sp$params)$type, "text")
    rls <- Find(function(x) x$id == "reverse_log_scale", sp$params)
    expect_identical(.default_values(list(sp), disk = TRUE)[[1L]]$reverse_log_scale, "FALSE")
    expect_identical(.default_values(list(sp), disk = FALSE)[[1L]]$reverse_log_scale, "TRUE")
    expect_identical(rls$default, "TRUE")
})

test_that("cluster entries write their R code", {
    steps <- .analysis_steps()
    up <- list(mg_groups = list(column_name = "cell_type"))
    p <- list(method = "scran", mode = "one_vs_all", group_1 = "", group_2 = "",
        pval = 0.01, logFC = 0.5, min_feats = 10L)
    expect_identical(steps$mg_markers$code(p, up), paste0(
        "markers <- findMarkers_one_vs_all(g, expression_values = \"normalized\", ",
        "cluster_column = \"cell_type\", method = \"scran\", pval = 0.01, logFC = 0.5, ",
        "min_feats = 10)"))
    p$mode <- "pair"; p$group_1 <- "Myeloid, T/NK"; p$method <- "gini"
    code <- steps$mg_markers$code(p, up)
    expect_match(code, 'findMarkers(g, expression_values = "normalized"', fixed = TRUE)
    expect_match(code, 'method = "gini", group_1 = c("Myeloid", "T/NK")', fixed = TRUE)
    expect_match(code, 'group_2 = setdiff(unique(pDataDT(g)[["cell_type"]]), c("Myeloid", "T/NK"))',
        fixed = TRUE)
    expect_match(code, 'group_2_name = "rest"', fixed = TRUE)
    p$group_2 <- "B/Plasma"
    expect_match(steps$mg_markers$code(p, list(mg_groups = list(column_name = "cell_type"),
        normalize = list(scale = TRUE))), 'expression_values = "scaled".*group_2 = "B/Plasma"')

    p <- list(selected_clusters = "2, 3", resolution = 0.5, k_neighbors = 10L,
        n_iterations = 20L, reverse_log_scale = FALSE, difference_in_cov = 1,
        hvf_min_perc_cells = 5, hvf_mean_expr_det = 1, min_nr_of_hvf = 5L,
        scale_unit = TRUE, ncp = 20L, dimensions_to_use = 1:20)
    code <- steps$sc_subcluster$code(p, list())
    expect_match(code, 'selected <- c("2", "3")', fixed = TRUE)
    expect_match(code, "reverse_log_scale = FALSE, difference_in_cov = 1", fixed = TRUE)
    expect_match(code, "ncp = min(20, length(ids) - 1, length(use))", fixed = TRUE)
    expect_match(code, "dimensions_to_use = intersect(1:20, seq_len(npc)), k = 10", fixed = TRUE)
    expect_match(code, "doLeidenCluster(tg, resolution = 0.5, n_iterations = 20", fixed = TRUE)
    expect_match(code, "sc_subcluster = paste0(parent", fixed = TRUE)
    p$selected_clusters <- ""
    expect_match(steps$sc_subcluster$code(p, list()), "selected <- clusters", fixed = TRUE)

    up <- list(ct_groups = list(column_name = "leiden_clus"))
    code <- steps$ct_tree$code(list(feats = "hvf", cor = "pearson", distance = "average"), up)
    expect_match(code, 'feats <- fDataDT(g)[hvf == "yes"]$feat_ID', fixed = TRUE)
    expect_match(code, paste0('calculateClusterTree(g, expression_values = "normalized", ',
        'cluster_column = "leiden_clus", feats = feats, cor = "pearson", distance = "average")'),
        fixed = TRUE)
    expect_match(steps$ct_tree$code(list(feats = NULL, cor = "spearman", distance = "ward.D2"),
        up), "feats <- NULL", fixed = TRUE)
    expect_identical(steps$ct_markers$code(list(method = "scran", lfc_cut = 0.25,
        fdr_cut = 0.01), up), paste0("nm <- findClusterTreeMarkers(g, tree = tree, ",
        "expression_values = \"normalized\", cluster_column = \"leiden_clus\", ",
        "method = \"scran\", lfc_cut = 0.25, fdr_cut = 0.01)"))
    expect_identical(steps$sc_source$code(list(from = "object"), list()), "")
})

test_that("the cluster tree is drawn from link coordinates", {
    h <- stats::hclust(stats::dist(c(a = 0, b = 1, c = 5, d = 6.5)), method = "average")
    tree <- list(merge = h$merge, height = h$height, order = h$order, labels = h$labels)
    co <- .ct_dendrogram_coords(tree)
    expect_identical(nrow(co$links), 9L)
    expect_identical(co$leaves$label, h$labels[h$order])
    expect_equal(co$nodes$y, h$height)
    top <- co$nodes[which.max(co$nodes$y), ]
    expect_equal(top$x, mean(range(co$nodes$x[-which.max(co$nodes$y)])))
    expect_true(all(co$links$y2 >= co$links$y))
    spec <- .ct_dendrogram_spec(tree, data.frame(nodeID = 1:3, n_strong = c(5L, 3L, 9L)),
        color = "n_strong")
    expect_identical(vapply(spec$layer, function(l) l$mark$type, ""), c("rule", "point", "text"))
    expect_identical(spec$layer[[2L]]$encoding$color$field, "n_strong")
    fields <- unlist(lapply(spec$layer, function(l) c(names(l$data$values),
        vapply(l$encoding[setdiff(names(l$encoding), "tooltip")], `[[`, "", "field"))))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
    json <- .encode_ws_message("x", spec)
    expect_match(json, '"axis":null', fixed = TRUE)
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

.table_ids <- function(a) {
    tabs <- a$.__enclos_env__$private$tables
    unlist(lapply(tabs, function(x) vapply(x, `[[`, "", "id")), use.names = FALSE)
}

.table_of <- function(a, id) {
    tabs <- unlist(a$.__enclos_env__$private$tables, recursive = FALSE)
    Find(function(x) identical(x$id, id), tabs)
}

test_that("Markers between groups run each group vs all others and group 1 vs group 2", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "markers_groups", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        mg_source = list(from = "object"),
        mg_groups = list(column = "object:cell_type")))
    on.exit(a$close(), add = TRUE)
    ms <- c("mg_source", "mg_groups", "mg_markers")
    st <- function() vapply(a$status[ms], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("markers_groups")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$mg_markers$summary, "in 5 groups \\(scran, each group vs all others\\)")
    tab <- .table_of(a, "mg_markers")
    expect_identical(tab$feat, "feat")
    expect_true(all(c("group", "feat", "logFC", "FDR") %in% unlist(tab$columns)))
    expect_true(tab$n > 0L)
    expect_true(any(vapply(v$sent, function(m) m$type == "analysis_tables", NA)))
    expect_identical(nrow(a$history("markers_groups")), 1L)
    expect_match(a$code("markers_groups"),
        'findMarkers_one_vs_all(g, expression_values = "normalized", cluster_column = "cell_type"',
        fixed = TRUE)

    secs <- a$status$mg_groups$secs
    a$set("mg_markers", mode = "pair", group_1 = "Myeloid")
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_identical(a$status$mg_groups$secs, secs)
    a$run("markers_groups")
    a$wait(120)
    expect_true(all(st() == "done"))
    expect_match(a$status$mg_markers$summary, "Myeloid vs rest", fixed = TRUE)
    groups <- unlist(.table_of(a, "mg_markers")$data[[1L]])
    expect_true(all(groups == "Myeloid"))
    expect_identical(nrow(a$history("markers_groups")), 2L)

    a$set("mg_markers", group_1 = "Myeloid", group_2 = "T/NK", method = "gini")
    a$run("markers_groups")
    a$wait(120)
    expect_identical(a$status$mg_markers$status, "done")
    expect_match(a$status$mg_markers$summary, "gini, Myeloid vs T/NK", fixed = TRUE)
    expect_true("comb_score" %in% unlist(.table_of(a, "mg_markers")$columns))

    a$set("mg_markers", group_1 = "Nope")
    a$run("markers_groups")
    a$wait(60)
    expect_identical(a$status$mg_markers$status, "error")
    expect_match(a$status$mg_markers$message, "not a group of the column: Nope", fixed = TRUE)
})

test_that("Subclustering splits the chosen Leiden clusters", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "subcluster", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        sc_source = list(from = "object"),
        sc_subcluster = list(selected_clusters = "2, 3")))
    on.exit(a$close(), add = TRUE)
    ss <- c("sc_source", "sc_subcluster")
    st <- function() vapply(a$status[ss], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("subcluster")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$sc_source$summary, "5 Leiden clusters")
    expect_match(a$status$sc_subcluster$summary, "2 of 5 clusters split")
    expect_true("sc_subcluster" %in% names(v$meta))
    cm <- as.data.frame(GiottoClass::pDataDT(g))
    sc <- as.character(v$meta$sc_subcluster[match(cm$cell_ID, v$meta$cell_ID)])
    expect_true(all(sc[cm$leiden_clus == 1] == "1.1"))
    expect_true(length(unique(sc[cm$leiden_clus == 2])) > 1L)
    expect_identical(sub("\\..*$", "", sc), as.character(cm$leiden_clus))
    expect_identical(v$panels$sc_sizes$mark$type, "bar")
    expect_true("sc_sizes" %in% .table_ids(a))
    expect_identical(nrow(a$history("subcluster")), 1L)
    expect_match(a$code("subcluster"), 'selected <- c("2", "3")', fixed = TRUE)

    a$set("sc_subcluster", resolution = 1)
    a$wait(10)
    expect_identical(unname(st()), c("done", "stale"))

    a$set("sc_subcluster", selected_clusters = "9")
    a$run("subcluster")
    a$wait(60)
    expect_identical(a$status$sc_subcluster$status, "error")
    expect_match(a$status$sc_subcluster$message, "not a cluster of leiden_clus: 9", fixed = TRUE)
})

test_that("Cluster tree follows the Leiden clusters of the Preprocessing tab", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "aggregated")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "cluster_tree", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20)))
    on.exit(a$close(), add = TRUE)
    cs <- c("ct_source", "ct_groups", "ct_tree", "ct_markers")
    st <- function() vapply(a$status[cs], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    priv <- a$.__enclos_env__$private
    expect_identical(priv$resolve_column("ct_groups"), "analysis:leiden_clus")

    a$run("cluster_tree")
    a$wait(300)
    expect_true(all(st() == "done"))
    n_cl <- length(unique(stats::na.omit(v$meta$leiden_clus)))
    expect_match(a$status$ct_tree$summary, sprintf("^%d clusters, %d splits", n_cl, n_cl - 1L))
    expect_false(grepl("all features", a$status$ct_tree$summary))
    spec <- v$panels$ct_dendrogram
    expect_identical(vapply(spec$layer, function(l) l$mark$type, ""), c("rule", "point", "text"))
    expect_identical(nrow(spec$layer[[3L]]$data$values), n_cl)
    expect_identical(nrow(spec$layer[[1L]]$data$values), 3L * (n_cl - 1L))
    expect_identical(v$panels$ct_node_markers$layer[[2L]]$encoding$color$field, "n_strong")
    expect_true(all(c("ct_splits", "ct_nodes", "ct_markers") %in% .table_ids(a)))
    expect_identical(.table_of(a, "ct_markers")$feat, "feat")
    expect_identical(.table_of(a, "ct_splits")$n, n_cl - 1L)
    expect_identical(nrow(a$history("cluster_tree")), 1L)
    expect_match(a$code("cluster_tree"), 'cluster_column = "leiden_clus"', fixed = TRUE)

    a$set("ct_tree", distance = "ward.D2")
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale", "stale"))
    a$run(step = "ct_tree")
    a$wait(120)
    expect_identical(unname(st()), c("done", "done", "done", "stale"))
    expect_match(a$status$ct_tree$summary, "ward.D2", fixed = TRUE)
})
