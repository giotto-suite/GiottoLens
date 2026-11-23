# ── Generated code and parameters ───────────────────────────────────────────

test_that("Spatial interactions code follows the parameters", {
    steps <- .analysis_steps()
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

test_that("the Spatial interactions proximity pick gives the clicked pair", {
    pick <- .analysis_entry_interactions()$steps$proximity$pick
    expect_identical(pick(list(type_a = list("T"), type_b = list("B")), list(), list()),
        list(pair = c("T", "B")))
})

test_that("spatial network settings apply to their method only", {
    net <- .step_network(input = NULL)
    expect_true(.param_shown(.par(net, "radius"), list(network = "new", method = "radius")))
    expect_false(.param_shown(.par(net, "radius"), list(network = "new", method = "kNN")))
    expect_true(.param_shown(.par(net, "maximum_distance_delaunay"), list(network = "new",
        method = "Delaunay")))
    expect_false(.param_shown(.par(net, "maximum_distance_delaunay"), list(method = "kNN")))
    expect_true(.param_shown(.par(net, "options"), list(network = "new", method = "Delaunay",
        delaunay_method = "delaunayn_geometry")))
    expect_false(.param_shown(.par(net, "options"), list(method = "Delaunay",
        delaunay_method = "deldir")))
    expect_true(.param_shown(.par(net, "minimum_k"), list(network = "new", method = "radius")))
    expect_false(.param_shown(.par(net, "minimum_k"), list(network = "kNN_network")))
    expect_identical(is.null(.par(net, "S")), !requireNamespace("RTriangle", quietly = TRUE))
})

# ── Runs ────────────────────────────────────────────────────────────────────

test_that("Spatial interactions run only when asked; advanced network and proximity settings reach Giotto", {
    r <- lens_analysis_rig(analyses = "interactions", params = c(lens_analysis_params, list(
        groups = list(column = "object:band"),
        proximity = list(number_of_simulations = 50))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    ist <- c("groups", "spatial_network", "proximity")
    st <- function() step_status(a, ist)
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
    fields <- .spec_fields(spec)
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

    a$set("spatial_network", method = "Delaunay", maximum_distance_delaunay = 40,
        minimum_k = 1, dimensions = 1:2)
    a$set("proximity", seed_number = 7)
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

test_that("History brings back runs; analyses are added and removed; interactions follow the Preprocessing cell types", {
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
    expect_true(all(step_status(a, c("groups", "spatial_network", "proximity")) == "done"))
    expect_false(is.null(r$panels()$proximity))
    a$wait(30)
    expect_identical(a$history("interactions")$current, c(TRUE, FALSE))

    a$remove("interactions")
    expect_identical(names(a$analyses()), "preprocess")
    expect_null(a$status$proximity)
    expect_null(r$panels()$proximity)
    a$add("interactions")
    expect_identical(nrow(a$history("interactions")), 2L)

    # Added again, the analysis keeps its values: with no column, the groups
    # step takes the Preprocessing tab's cell types
    a$set("groups", column = "")
    st <- function() step_status(a, c("groups", "spatial_network", "proximity"))
    expect_true(all(st() == "stale"))
    expect_identical(a$.__enclos_env__$private$resolve_column("groups"), "analysis:cell_type")
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
