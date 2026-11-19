# Markers between groups

test_that("the Markers between groups entry has its fields, prefixed steps and order", {
    cat <- .analysis_catalog()
    e <- cat$markers_groups
    expect_identical(e$id, "markers_groups")
    expect_identical(e$order, 60)
    expect_false(e$auto)
    expect_true(all(startsWith(names(e$steps), "mg_")))
    expect_identical(e$steps[[1L]]$kind, "source")
    expect_null(e$steps[[1L]]$input)
    for (s in names(e$steps)) expect_true(is.function(e$steps[[s]]$code), info = s)
    expect_true(length(e$inputs) > 0L && length(e$outputs) > 0L)
    expect_identical(names(e$steps), c("mg_source", "mg_groups", "mg_markers"))
    expect_identical(e$steps$mg_groups$kind, "groups")
    types <- function(st) vapply(st$params, `[[`, "", "type")
    mp <- e$steps$mg_markers
    expect_identical(unname(types(mp)[vapply(mp$params, `[[`, "", "id") %in%
        c("group_1", "group_2")]), c("text", "text"))
})

test_that("Markers between groups write their R code", {
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
        mg_source = list(expression_values = "scaled"))),
        'expression_values = "scaled".*group_2 = "B/Plasma"')
})

test_that("Markers between groups offer advanced settings with Giotto's defaults", {
    steps <- .analysis_steps()
    par <- function(s, id) Find(function(q) identical(q$id, id), steps[[s]]$params)
    adv <- function(s) vapply(Filter(function(q) isTRUE(q$advanced), steps[[s]]$params),
        `[[`, "", "id")
    expect_identical(adv("mg_markers"), c("subset_clusters", "pair_min_feats", "min_expression",
        "min_detection", "min_expression_gini", "min_detection_gini", "detection_threshold",
        "min_length", "rank_score"))
    expect_false(any(c("method", "mode", "pval", "logFC", "min_feats") %in% adv("mg_markers")))
    d <- .default_values(steps["mg_markers"], disk = TRUE)
    expect_identical(d$mg_markers[c("subset_clusters", "pair_min_feats", "min_expression",
        "min_detection", "min_expression_gini", "detection_threshold", "min_length",
        "rank_score")], list(subset_clusters = "", pair_min_feats = "4", min_expression = "0.5",
        min_detection = "0.5", min_expression_gini = "auto", detection_threshold = "0",
        min_length = "0", rank_score = "auto"))
    expect_null(.param_r(par("mg_markers", "rank_score"), "auto"))

    expect_identical(par("mg_markers", "min_expression")$show_if, list(method = "gini"))
    expect_identical(par("mg_markers", "pair_min_feats")$show_if,
        list(mode = "pair", method = "gini"))
    expect_identical(par("mg_markers", "pval")$show_if$method, .mg_stat_methods())
})

test_that("Markers between groups write changed advanced settings into their R code", {
    steps <- .analysis_steps()
    vals <- function(s, over = list()) {
        d <- .default_values(steps[s], disk = FALSE)[[1L]]
        for (k in names(over)) d[[k]] <- over[[k]]
        p <- list()
        for (par in steps[[s]]$params) p[par$id] <- list(.param_r(par, d[[par$id]]))
        p
    }
    up <- list(mg_groups = list(column_name = "cell_type"))
    base <- steps$mg_markers$code(vals("mg_markers"), up)
    expect_identical(base, paste0("markers <- findMarkers_one_vs_all(g, expression_values = ",
        "\"normalized\", cluster_column = \"cell_type\", method = \"scran\", pval = 0.01, ",
        "logFC = 0.5, min_feats = 10)"))
    expect_identical(steps$mg_markers$code(vals("mg_markers", list(min_expression = "0.3")), up),
        base)
    code <- steps$mg_markers$code(vals("mg_markers", list(method = "gini",
        subset_clusters = "Myeloid, T/NK", min_expression = "0.3", rank_score = "2",
        pair_min_feats = "8")), up)
    expect_true(endsWith(code, paste0('min_feats = 10, subset_clusters = c("Myeloid", "T/NK"), ',
        'min_expression = 0.3, rank_score = 2)')))
    expect_false(grepl("min_feats = 8", code, fixed = TRUE))
    code <- steps$mg_markers$code(vals("mg_markers", list(method = "gini", mode = "pair",
        group_1 = "A", min_detection_gini = "0.2", pair_min_feats = "8",
        subset_clusters = "B")), up)
    expect_match(code, 'group_2_name = "rest", min_detection_gini = 0.2, min_feats = 8)$')
    expect_false(grepl("subset_clusters", code, fixed = TRUE))
})


.table_ids <- function(a) {
    tabs <- a$.__enclos_env__$private$tables
    unlist(lapply(tabs, function(x) vapply(x, `[[`, "", "id")), use.names = FALSE)
}

.table_of <- function(a, id) {
    tabs <- unlist(a$.__enclos_env__$private$tables, recursive = FALSE)
    Find(function(x) identical(x$id, id), tabs)
}

test_that("Markers between groups run each group vs all others and group 1 vs group 2", {
    r <- lens_analysis_rig(analyses = "markers_groups", params = c(lens_analysis_params, list(
        mg_source = list(from = "object"),
        mg_groups = list(column = "object:band"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    ms <- c("mg_source", "mg_groups", "mg_markers")
    st <- function() vapply(a$status[ms], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("markers_groups")
    a$wait(300)
    expect_true(all(st() == "done"))
    expect_match(a$status$mg_markers$summary, "in 3 groups \\(scran, each group vs all others\\)")
    tab <- .table_of(a, "mg_markers")
    expect_identical(tab$feat, "feat")
    expect_true(all(c("group", "feat", "logFC", "FDR") %in% unlist(tab$columns)))
    expect_true(tab$n > 0L)
    expect_true(any(vapply(v$sent(), function(m) m$type == "analysis_tables", NA)))
    expect_identical(nrow(a$history("markers_groups")), 1L)
    # The loaded object has raw values only
    expect_match(a$code("markers_groups"),
        'findMarkers_one_vs_all(g, expression_values = "raw", cluster_column = "band"',
        fixed = TRUE)

    secs <- a$status$mg_groups$secs
    a$set("mg_markers", mode = "pair", group_1 = "A")
    a$wait(10)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_identical(a$status$mg_groups$secs, secs)
    a$run("markers_groups")
    a$wait(120)
    expect_true(all(st() == "done"))
    expect_match(a$status$mg_markers$summary, "A vs rest", fixed = TRUE)
    groups <- unlist(.table_of(a, "mg_markers")$data[[1L]])
    expect_true(all(groups == "A"))
    expect_identical(nrow(a$history("markers_groups")), 2L)

    a$set("mg_markers", group_1 = "A", group_2 = "B", method = "gini")
    a$run("markers_groups")
    a$wait(120)
    expect_identical(a$status$mg_markers$status, "done")
    expect_match(a$status$mg_markers$summary, "gini, A vs B", fixed = TRUE)
    expect_true("comb_score" %in% unlist(.table_of(a, "mg_markers")$columns))

    a$set("mg_markers", group_1 = "Nope")
    a$run("markers_groups")
    a$wait(60)
    expect_identical(a$status$mg_markers$status, "error")
    expect_match(a$status$mg_markers$message, "not a group of the column: Nope", fixed = TRUE)
})


test_that("Markers between groups run with advanced gini settings", {
    r <- lens_analysis_rig(analyses = "markers_groups", params = c(lens_analysis_params, list(
        mg_source = list(from = "object"),
        mg_groups = list(column = "object:band"),
        mg_markers = list(method = "gini", subset_clusters = "A, B, C",
            min_expression = 0.3, min_detection = 0.3, min_expression_gini = 0.1,
            detection_threshold = 0.5, min_length = 10, rank_score = 2, min_feats = 3))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    a$wait(300)
    a$run("markers_groups")
    a$wait(300)
    expect_identical(a$status$mg_markers$status, "done")
    expect_match(a$status$mg_markers$summary, "in 3 groups (gini, each group vs all others)",
        fixed = TRUE)
    groups <- unique(unlist(.table_of(a, "mg_markers")$data[[1L]]))
    expect_true(all(groups %in% c("A", "B", "C")))
    expect_match(a$code("markers_groups"), paste0('subset_clusters = c("A", "B", ',
        '"C"), min_expression = 0.3, min_detection = 0.3, min_expression_gini = 0.1, ',
        'detection_threshold = 0.5, min_length = 10, rank_score = 2)'), fixed = TRUE)

    a$set("mg_markers", mode = "pair", group_1 = "A", pair_min_feats = 8)
    a$run("markers_groups")
    a$wait(120)
    expect_identical(a$status$mg_markers$status, "done")
    expect_match(a$code("markers_groups"), "min_feats = 8)", fixed = TRUE)

    a$set("mg_markers", mode = "one_vs_all", subset_clusters = "A")
    a$run("markers_groups")
    a$wait(60)
    expect_identical(a$status$mg_markers$status, "error")
    expect_match(a$status$mg_markers$message, "groups compared needs at least two groups",
        fixed = TRUE)
})

