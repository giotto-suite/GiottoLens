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

test_that("Niche defaults and code follow the parameters", {
    st <- .analysis_entry_niches()$steps
    d <- .default_values(st, disk = TRUE)
    expect_identical(d$nc_kmeans[c("k", "iter_max", "nstart", "seed")],
        list(k = "7", iter_max = "1000", nstart = "100", seed = "1234"))
    up <- list(nc_network = list(method = "kNN"), nc_groups = list(column_name = "cell_type"))
    expect_identical(st$nc_proportions$code(list(), up), paste0(
        "g <- calculateSpatCellMetadataProportions(g, spat_network = \"lens_spatial\", ",
        "metadata_column = \"cell_type\", name = \"nc_proportion\")"))
    code <- st$nc_kmeans$code(list(k = 5L, iter_max = 1000L, nstart = 100L, seed = 1234L), up)
    expect_match(code, "set.seed(1234)", fixed = TRUE)
    expect_match(code, "centers = 5, iter.max = 1000, nstart = 100", fixed = TRUE)
    expect_match(code, "nc_niche = paste(\"niche\"", fixed = TRUE)
    expect_silent(parse(text = code))
    spec <- .nc_composition_spec(data.frame(niche = rep(c("niche 1", "niche 2"), each = 2),
        cell_type = rep(c("A", "B"), 2), proportion = c(0.9, 0.1, 0.2, 0.8), cells = 10L),
        c("niche 1", "niche 2"))
    fields <- c(spec$encoding$x$field, spec$encoding$y$field, spec$encoding$color$field,
        vapply(spec$encoding$tooltip, `[[`, "", "field"))
    expect_true(all(fields %in% names(spec$data$values)))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
})

test_that("Interaction-changed genes defaults and code follow the parameters", {
    st <- .analysis_entry_icf()$steps
    tests <- Find(function(p) p$id == "diff_test", st$icf_test$params)
    expect_identical(vapply(.offered(tests$choices, TRUE), `[[`, "", "value"), "permutation")
    expect_length(.offered(tests$choices, FALSE), 4L)
    d <- .default_values(st, disk = FALSE)$icf_test
    expect_identical(d[c("diff_test", "nr_permutations", "adjust_method", "min_log2fc",
        "max_padj", "min_cells")], list(diff_test = "permutation", nr_permutations = "1000",
        adjust_method = "fdr", min_log2fc = "0.2", max_padj = "0.1", min_cells = "4"))
    up <- list(icf_network = list(method = "kNN"),
        icf_groups = list(column_name = "cell_type"), icf_source = list(from = "object"))
    code <- st$icf_test$code(list(diff_test = "permutation", nr_permutations = 100L,
        adjust_method = "fdr", min_log2fc = 0.5, max_padj = 0.05, min_cells = 4L), up)
    expect_match(code, paste0("cluster_column = \"cell_type\", spatial_network_name = ",
        "\"lens_spatial\", diff_test = \"permutation\", nr_permutations = 100, ",
        "adjust_method = \"fdr\", do_parallel = FALSE"), fixed = TRUE)
    expect_match(code, "abs(log2fc) >= 0.5 & p.adj <= 0.05", fixed = TRUE)
    expect_silent(parse(text = code))
})

# The steps on the 400 um MERSCOPE vault, against a stand-in viewer
mini_vault <- "/Users/jeffreysheridan/Documents/Projects/GiottoDev/vaults/render_mini_20261103/giotto_project"

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

test_that("Niches label cells and show the niche composition", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "niches", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        nc_groups = list(column = "object:cell_type"),
        nc_kmeans = list(k = 5)))
    on.exit(a$close(), add = TRUE)
    ist <- c("nc_groups", "nc_network", "nc_proportions", "nc_kmeans")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    a$run("niches")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$nc_kmeans$summary, "^5 niches: niche 1 ")
    expect_true("nc_niche" %in% names(v$meta))
    typed <- GiottoClass::pDataDT(g)
    typed <- typed$cell_ID[!is.na(typed$cell_type)]
    niche <- v$meta$nc_niche[match(typed, v$meta$cell_ID)]
    expect_type(v$meta$nc_niche, "character")
    expect_setequal(unique(stats::na.omit(niche)), paste("niche", 1:5))
    sizes <- as.integer(table(factor(niche, levels = paste("niche", 1:5))))
    expect_false(is.unsorted(rev(sizes)))
    spec <- v$panels$nc_composition
    expect_identical(spec$mark$type, "rect")
    n_types <- length(unique(stats::na.omit(GiottoClass::pDataDT(g)$cell_type)))
    expect_identical(nrow(spec$data$values), as.integer(5 * n_types))
    sums <- tapply(spec$data$values$proportion, spec$data$values$niche, sum)
    expect_equal(as.numeric(sums), rep(1, 5), tolerance = 1e-6)
    expect_match(a$code("niches"), "centers = 5, iter.max = 1000, nstart = 100", fixed = TRUE)
    expect_identical(nrow(a$history("niches")), 1L)

    secs <- a$status$nc_proportions$secs
    a$set("nc_kmeans", k = 4)
    a$wait(30)
    expect_identical(unname(st()), c("done", "done", "done", "stale"))
    expect_identical(a$status$nc_proportions$secs, secs)
    expect_identical(nrow(a$history("niches")), 1L)
})

test_that("Interaction-changed genes fill a gene table", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "icf", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        icf_source = list(from = "object"),
        icf_groups = list(column = "object:cell_type"),
        icf_test = list(nr_permutations = 5, adjust_method = "none")))
    on.exit(a$close(), add = TRUE)
    ist <- c("icf_source", "icf_groups", "icf_network", "icf_test")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    priv <- a$.__enclos_env__$private
    sch <- priv$schema()
    tp <- Find(function(x) x$id == "icf_test", sch$steps)$params
    dt <- Find(function(x) x$id == "diff_test", tp)
    expect_identical(vapply(dt$choices, `[[`, "", "value"), "permutation")
    a$run("icf")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$icf_test$summary, "pairs tested")
    tab <- priv$tables$icf_test[[1L]]
    expect_identical(tab$id, "icf_genes")
    expect_identical(tab$feat, "gene")
    expect_identical(unlist(tab$columns), c("gene", "cell_type", "neighbor_type", "nr_select",
        "nr_other", "sel", "other", "log2fc", "p_adj"))
    expect_gt(tab$n, 0L)
    expect_match(tab$note, "assigned to the wrong cell", fixed = TRUE)
    cols <- stats::setNames(tab$data, unlist(tab$columns))
    expect_true(all(abs(unlist(cols$log2fc)) >= 0.2))
    expect_true(all(unlist(cols$p_adj) <= 0.1))
    expect_true(all(unlist(cols$nr_select) >= 4))
    expect_match(a$code("icf"), "diff_test = \"permutation\", nr_permutations = 5", fixed = TRUE)
    expect_identical(nrow(a$history("icf")), 1L)

    secs <- a$status$icf_test$secs
    n_before <- tab$n
    a$set("icf_test", min_log2fc = 0.5)
    a$wait(30)
    expect_true(all(st() == "done"))
    expect_identical(a$status$icf_test$secs, secs)
    tab2 <- priv$tables$icf_test[[1L]]
    expect_lte(tab2$n, n_before)
    cols2 <- stats::setNames(tab2$data, unlist(tab2$columns))
    expect_true(all(abs(unlist(cols2$log2fc)) >= 0.5))
    a$set("icf_test", nr_permutations = 6)
    a$wait(30)
    expect_identical(unname(st()), c("done", "done", "done", "stale"))
    a$set("icf_groups", column = "object:leiden_clus")
    a$wait(30)
    expect_identical(unname(st()), c("done", "stale", "stale", "stale"))
    expect_identical(nrow(a$history("icf")), 1L)
})
