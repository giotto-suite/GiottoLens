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
    expect_identical(d$nc_kmeans[c("k", "k_max", "auto_cells", "iter_max", "nstart", "seed")],
        list(k = "auto", k_max = "15", auto_cells = "3000", iter_max = "1000", nstart = "100",
            seed = "1234"))
    up <- list(nc_network = list(method = "kNN"), nc_groups = list(column_name = "cell_type"))
    expect_identical(st$nc_proportions$code(list(), up), paste0(
        "g <- calculateSpatCellMetadataProportions(g, spat_network = \"spatial_network\", ",
        "metadata_column = \"cell_type\", name = \"nc_proportion\")"))
    code <- st$nc_kmeans$code(list(k = 5L, iter_max = 1000L, nstart = 100L, seed = 1234L), up)
    expect_match(code, "set.seed(1234)", fixed = TRUE)
    expect_match(code, "centers = 5, iter.max = 1000, nstart = 100", fixed = TRUE)
    expect_match(code, "nc_niche = paste(\"niche\"", fixed = TRUE)
    expect_silent(parse(text = code))
    code <- st$nc_kmeans$code(list(k = NULL, k_max = 12L, auto_cells = 2000L, iter_max = 1000L,
        nstart = 100L, seed = 1234L), up)
    expect_match(code, "ks <- 2:12", fixed = TRUE)
    expect_match(code, "min(2000, nrow(prop_matrix))", fixed = TRUE)
    expect_match(code, "nstart = 10)$cluster", fixed = TRUE)
    expect_match(code, "centers = k, iter.max = 1000, nstart = 100", fixed = TRUE)
    expect_silent(parse(text = code))
    out <- st$nc_kmeans$view(list(composition = data.frame(niche = "niche 1", cell_type = "A",
        proportion = 1, cells = 1L), order = "niche 1",
        k_scores = data.frame(k = 2:3, silhouette = c(0.4, 0.3))), list())
    expect_identical(out$color, "nc_niche")
    expect_identical(vapply(out$panels, `[[`, "", "id"), c("nc_composition", "nc_k"))
    pick <- .analysis_entry_interactions()$steps$proximity$pick
    expect_identical(pick(list(type_a = list("T"), type_b = list("B")), list(), list()),
        list(pair = c("T", "B")))
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
        "\"spatial_network\", diff_test = \"permutation\", nr_permutations = 100, ",
        "adjust_method = \"fdr\", do_parallel = FALSE"), fixed = TRUE)
    expect_match(code, "abs(log2fc) >= 0.5 & p.adj <= 0.05", fixed = TRUE)
    expect_silent(parse(text = code))
})

test_that("Niche advanced settings have kmeans defaults and reach the code", {
    st <- .analysis_entry_niches()$steps
    km <- st$nc_kmeans$params
    adv <- vapply(km, function(q) isTRUE(q$advanced), NA)
    names(adv) <- vapply(km, `[[`, "", "id")
    expect_identical(adv, c(k = FALSE, k_max = FALSE, auto_cells = FALSE, iter_max = TRUE,
        nstart = TRUE, algorithm = TRUE, seed = TRUE, name = FALSE))
    expect_identical(.default_values(st, disk = TRUE)$nc_kmeans$algorithm, "Hartigan-Wong")
    al <- Find(function(q) q$id == "algorithm", km)
    expect_identical(vapply(al$choices, `[[`, "", "value"),
        c("Hartigan-Wong", "Lloyd", "Forgy", "MacQueen"))
    up <- list(nc_groups = list(column_name = "cell_type"))
    p <- list(k = 5L, iter_max = 1000L, nstart = 100L, algorithm = "Hartigan-Wong", seed = 1234L)
    expect_false(grepl("algorithm", st$nc_kmeans$code(p, up), fixed = TRUE))
    p$algorithm <- "Lloyd"; p$seed <- 7L
    code <- st$nc_kmeans$code(p, up)
    expect_match(code, "nstart = 100, algorithm = \"Lloyd\")", fixed = TRUE)
    expect_match(code, "set.seed(7)", fixed = TRUE)
    expect_silent(parse(text = code))
})

test_that("Interaction-changed genes advanced settings have Giotto defaults", {
    skip_if_not_installed("Giotto")
    st <- .analysis_entry_icf()$steps
    ent <- .analysis_catalog()$icf$steps$icf_test
    new <- c("selected_feats", "minimum_unique_cells", "minimum_unique_int_cells",
        "mean_method", "offset", "exclude_selected_cells_from_test", "seed_number")
    pars <- stats::setNames(ent$params, vapply(ent$params, `[[`, "", "id"))
    for (id in new) {
        expect_true(isTRUE(pars[[id]]$advanced), info = id)
        expect_true(nzchar(pars[[id]]$help %||% ""), info = id)
    }
    for (id in c("diff_test", "nr_permutations", "adjust_method", "min_log2fc", "max_padj",
        "min_cells")) expect_false(isTRUE(pars[[id]]$advanced), info = id)
    expect_false("set_seed" %in% names(pars))
    expect_identical(pars$seed_number$show_if, list(diff_test = "permutation"))
    expect_identical(vapply(.offered(pars$mean_method$choices, TRUE), `[[`, "", "value"),
        "arithmic")
    expect_length(.offered(pars$mean_method$choices, FALSE), 2L)
    d <- .default_values(st, disk = TRUE)$icf_test
    expect_identical(d[new], list(selected_feats = "", minimum_unique_cells = "1",
        minimum_unique_int_cells = "1", mean_method = "arithmic", offset = "0.1",
        exclude_selected_cells_from_test = "TRUE", seed_number = "1234"))
    defs <- formals(Giotto::findInteractionChangedFeats)
    expect_identical(eval(defs$minimum_unique_cells), 1)
    expect_identical(eval(defs$offset), 0.1)
    expect_identical(eval(defs$seed_number), 1234)
    expect_identical(eval(defs$mean_method)[[1L]], "arithmic")
})

test_that("Interaction-changed genes code lists changed advanced settings only", {
    st <- .analysis_entry_icf()$steps
    up <- list(icf_groups = list(column_name = "cell_type"))
    p <- list(diff_test = "permutation", nr_permutations = 100L, adjust_method = "fdr",
        min_log2fc = 0.2, max_padj = 0.1, min_cells = 4L, selected_feats = "",
        minimum_unique_cells = 1L, minimum_unique_int_cells = 1L, mean_method = "arithmic",
        offset = 0.1, exclude_selected_cells_from_test = TRUE, seed_number = 1234L)
    code <- st$icf_test$code(p, up)
    expect_match(code, "adjust_method = \"fdr\", do_parallel = FALSE)", fixed = TRUE)
    p2 <- utils::modifyList(p, list(selected_feats = "CD3E, EPCAM", minimum_unique_cells = 3L,
        minimum_unique_int_cells = 2L, mean_method = "geometric", offset = 0.5,
        exclude_selected_cells_from_test = FALSE, seed_number = 99L))
    code <- st$icf_test$code(p2, up)
    expect_match(code, paste0("adjust_method = \"fdr\", selected_feats = c(\"CD3E\", \"EPCAM\"), ",
        "minimum_unique_cells = 3, minimum_unique_int_cells = 2, mean_method = \"geometric\", ",
        "offset = 0.5, exclude_selected_cells_from_test = FALSE, seed_number = 99, ",
        "do_parallel = FALSE)"), fixed = TRUE)
    expect_silent(parse(text = code))
    code <- st$icf_test$code(utils::modifyList(p, list(diff_test = "wilcox", seed_number = 99L)),
        up)
    expect_false(grepl("seed_number", code, fixed = TRUE))
})

test_that("Niches label cells and show the niche composition", {
    r <- lens_analysis_rig(analyses = "niches", params = c(lens_analysis_params, list(
        nc_groups = list(column = "object:band"),
        nc_kmeans = list(k = 5))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    ist <- c("nc_groups", "nc_network", "nc_proportions", "nc_kmeans")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))
    a$run("niches")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$nc_kmeans$summary, "^5 niches \\(silhouette [0-9.]+\\): niche 1 ")
    expect_true("nc_niche" %in% names(v$meta()))
    typed <- r$fx$meta$cell_ID
    niche <- v$meta()$nc_niche[match(typed, v$meta()$cell_ID)]
    expect_type(v$meta()$nc_niche, "character")
    expect_setequal(unique(stats::na.omit(niche)), paste("niche", 1:5))
    sizes <- as.integer(table(factor(niche, levels = paste("niche", 1:5))))
    expect_false(is.unsorted(rev(sizes)))
    spec <- v$panels()$nc_composition
    expect_identical(spec$mark$type, "rect")
    n_types <- 3L
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
    r <- lens_analysis_rig(analyses = "icf", params = c(lens_analysis_params, list(
        icf_source = list(from = "object"),
        icf_groups = list(column = "object:band"),
        icf_test = list(nr_permutations = 5, adjust_method = "none"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
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
    a$set("icf_groups", column = "analysis:cell_type")
    a$wait(30)
    expect_identical(unname(st()), c("done", "stale", "stale", "stale"))
    expect_identical(nrow(a$history("icf")), 1L)
})

test_that("worker helpers score clusterings and count calls", {
    set.seed(1)
    x <- rbind(matrix(stats::rnorm(60), ncol = 2), matrix(stats::rnorm(60, 4), ncol = 2), c(9, 9))
    d <- as.matrix(stats::dist(x))
    cl <- c(rep(1L, 30), rep(2L, 30), 3L)
    expected <- vapply(seq_along(cl), function(i) {
        a <- if (sum(cl == cl[i]) > 1L) mean(d[i, cl == cl[i] & seq_along(cl) != i]) else NA
        b <- min(vapply(setdiff(unique(cl), cl[i]), function(k) mean(d[i, cl == k]), 1))
        if (is.na(a)) 0 else (b - a) / max(a, b)
    }, 1)
    expect_equal(.aw_silhouette(d, cl), mean(expected))

    w <- new.env()
    w$kept <- list()
    w$key <- "k1"
    progress <- tempfile()
    old <- mget(c(".lens_a", ".lens_progress", ".lens_progress_file", ".lens_progress_t",
        ".lens_tick"), envir = globalenv(), ifnotfound = list(NULL))
    on.exit(for (n in names(old)) if (is.null(old[[n]]))
        suppressWarnings(rm(list = n, envir = globalenv())) else assign(n, old[[n]], globalenv()),
        add = TRUE)
    assign(".lens_a", w, envir = globalenv())
    assign(".lens_progress", .job_fun(.lens_progress), envir = globalenv())
    assign(".lens_progress_file", progress, envir = globalenv())
    h <- .aw_helpers()
    h$.lens_keep(list(a = 1))
    expect_identical(h$.lens_kept(), list(a = 1))
    out <- h$.lens_count_calls({
        for (i in 1:3) stats::setNames(1, "a")
        "done"
    }, "stats", "setNames", 3, "calls")
    expect_identical(out, "done")
    expect_identical(readLines(progress), "3\t3\tcalls")
    expect_false(inherits(stats::setNames, "functionWithTrace"))
})

test_that("Niches run with advanced kmeans settings", {
    r <- lens_analysis_rig(analyses = "niches", params = c(lens_analysis_params, list(
        nc_groups = list(column = "object:band"),
        nc_kmeans = list(k = 4, iter_max = 50, nstart = 5, algorithm = "Lloyd", seed = 7))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    ist <- c("nc_groups", "nc_network", "nc_proportions", "nc_kmeans")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    a$run("niches")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$nc_kmeans$summary, "^4 niches \\(silhouette [0-9.]+\\): niche 1 ")
    expect_true("nc_niche" %in% names(v$meta()))
    code <- a$code("niches")
    expect_match(code, "centers = 4, iter.max = 50, nstart = 5, algorithm = \"Lloyd\")",
        fixed = TRUE)
    expect_match(code, "set.seed(7)", fixed = TRUE)
})

test_that("Interaction-changed genes run with advanced settings", {
    genes <- sprintf("gene%02d", 1:40)
    r <- lens_analysis_rig(analyses = "icf", params = c(lens_analysis_params, list(
        icf_source = list(from = "object"),
        icf_groups = list(column = "object:band"),
        icf_test = list(nr_permutations = 5, adjust_method = "none", max_padj = 1,
            min_log2fc = 0, min_cells = 1, selected_feats = genes,
            minimum_unique_cells = 3, minimum_unique_int_cells = 2,
            offset = 0.5,
            exclude_selected_cells_from_test = FALSE, seed_number = 99))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("icf_source", "icf_groups", "icf_network", "icf_test")
    st <- function() vapply(a$status[ist], `[[`, "", "status")
    a$wait(300)
    a$run("icf")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    tab <- a$.__enclos_env__$private$tables$icf_test[[1L]]
    expect_gt(tab$n, 0L)
    cols <- stats::setNames(tab$data, unlist(tab$columns))
    expect_true(all(unlist(cols$gene) %in% genes))
    expect_true(all(unlist(cols$nr_select) >= 3))
    expect_true(all(unlist(cols$nr_other) >= unlist(cols$nr_select)))
    expect_match(a$code("icf"), paste0("minimum_unique_cells = 3, minimum_unique_int_cells = 2, ",
        "offset = 0.5, exclude_selected_cells_from_test = FALSE, seed_number = 99"), fixed = TRUE)
})
