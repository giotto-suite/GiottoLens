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
    spec <- .nc_composition_spec(data.frame(niche = rep(c("niche 1", "niche 2"), each = 2),
        cell_type = rep(c("A", "B"), 2), proportion = c(0.9, 0.1, 0.2, 0.8), cells = 10L),
        c("niche 1", "niche 2"))
    fields <- .spec_fields(spec)
    expect_true(all(fields %in% names(spec$data$values)))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
})

test_that("Niche advanced settings have kmeans defaults and reach the code", {
    st <- .analysis_entry_niches()$steps
    km <- st$nc_kmeans$params
    adv <- vapply(km, function(q) isTRUE(q$advanced), NA)
    names(adv) <- vapply(km, `[[`, "", "id")
    expect_identical(adv, c(k = FALSE, k_max = FALSE, auto_cells = FALSE, iter_max = TRUE,
        nstart = TRUE, algorithm = TRUE, seed = TRUE, name = FALSE))
    expect_identical(.default_values(st, disk = TRUE)$nc_kmeans$algorithm, "Hartigan-Wong")
    al <- .par(st$nc_kmeans, "algorithm")
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

test_that("Niches label cells and show the niche composition, then run with advanced kmeans settings", {
    r <- lens_analysis_rig(analyses = "niches", params = c(lens_analysis_params, list(
        nc_groups = list(column = "object:band"),
        nc_kmeans = list(k = 5))), start = FALSE)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    ist <- c("nc_groups", "nc_network", "nc_proportions", "nc_kmeans")
    st <- function() step_status(a, ist)
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

    a$set("nc_kmeans", iter_max = 50, nstart = 5, algorithm = "Lloyd", seed = 7)
    a$run("niches")
    a$wait(180)
    expect_true(all(st() == "done"), info = paste(ist, st(), collapse = ", "))
    expect_match(a$status$nc_kmeans$summary, "^4 niches \\(silhouette [0-9.]+\\): niche 1 ")
    code <- a$code("niches")
    expect_match(code, "centers = 4, iter.max = 50, nstart = 5, algorithm = \"Lloyd\")",
        fixed = TRUE)
    expect_match(code, "set.seed(7)", fixed = TRUE)
})
