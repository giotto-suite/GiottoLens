# Expression values, result names and spatial networks by name

test_that("values and network parameters take names", {
    v <- .values_param(c("scaled", "normalized"))
    expect_identical(v$type, "values")
    expect_identical(.param_key(v, NULL), "")
    expect_identical(.param_key(v, " custom "), "custom")
    expect_error(.param_key(v, c("a", "b")), "one expression name")
    expect_identical(.param_r(v, "raw"), "raw")
    net <- Find(function(q) q$id == "network", .step_network(input = NULL)$params)
    expect_identical(.param_key(net, NULL), "new")
    expect_identical(.param_key(net, "Delaunay_network"), "Delaunay_network")
    expect_identical(.values_of(list(), list(list(), list(expression_values = "raw"))), "raw")
    expect_identical(.values_of(list(expression_values = "scaled"),
        list(list(expression_values = "raw"))), "scaled")
    expect_identical(.values_of(list(), list()), "normalized")
    expect_null(.preferred_network(character()))
    expect_identical(.preferred_network(c("mine", "kNN_network", "Delaunay_network")),
        "Delaunay_network")
    expect_identical(.preferred_network(c("mine", "other")), "mine")
})

test_that("Preprocessing results take names and the steps below use them", {
    steps <- .analysis_steps()
    nm <- .pre_names(list(pca = list(name = "pca_a"), network = list(type = "kNN"),
        leiden = list(name = ""), auto_type = list(method = "hypergeometric", name = "")))
    expect_identical(nm$pca, "pca_a")
    expect_identical(nm$network, "kNN.pca")
    expect_identical(nm$leiden, "leiden_clus")
    expect_identical(nm$auto_type, "hypergeometric")
    expect_identical(nm$labels, "cell_type")
    up <- list(pca = list(name = "pca_a"))
    code <- steps$network$code(list(type = "sNN", dimensions_to_use = 1:10, k = 30L,
        name = "nn_a"), up)
    expect_match(code, 'dim_reduction_name = "pca_a"', fixed = TRUE)
    expect_match(code, 'name = "nn_a")', fixed = TRUE)
    code <- steps$markers$code(list(method = "scran", expression_values = "normalized"),
        list(leiden = list(name = "clus_a")))
    expect_match(code, 'expression_values = "normalized", cluster_column = "clus_a"',
        fixed = TRUE)
    code <- steps$hvf$code(list(expression_values = "custom", method = "cov_groups"), list())
    expect_match(code, 'calculateHVF(g, expression_values = "custom"', fixed = TRUE)
})

test_that("an analysis uses another analysis's spatial network and chosen values", {
    r <- lens_analysis_rig(analyses = c("interactions", "niches", "markers_groups"),
        params = c(lens_analysis_params, list(
        mg_source = list(from = "object"),
        mg_groups = list(column = "object:band"),
        groups = list(column = "object:band"),
        spatial_network = list(method = "Delaunay", name = "near"),
        proximity = list(number_of_simulations = 20),
        nc_groups = list(column = "object:band"),
        nc_network = list(network = "near"),
        nc_kmeans = list(k = 3, name = "niche_a"))), network_dir = NULL)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    a$wait(300)
    priv <- a$.__enclos_env__$private
    sch <- priv$schema()
    par <- function(s, id) Find(function(q) q$id == id,
        Find(function(x) x$id == s, sch$steps)$params)
    net <- par("nc_network", "network")
    expect_identical(net$type, "choice")
    expect_identical(net$value, "near")
    expect_true("near" %in% vapply(net$choices, `[[`, "", "value"))
    expect_identical(priv$network_dep("nc_network"), "spatial_network")
    key0 <- priv$keys$nc_network

    a$run("interactions")
    a$wait(300)
    expect_identical(a$status$spatial_network$status, "done")
    expect_match(a$status$spatial_network$summary, "near:", fixed = TRUE)
    expect_match(a$code("interactions"), 'method = "Delaunay", delaunay_method = "delaunayn_geometry", name = "near")',
        fixed = TRUE)
    expect_match(a$code("interactions"), 'spatial_network_name = "near"', fixed = TRUE)
    expect_match(a$code("interactions"), '^activeSpatUnit\\(g\\) <- "cell"')

    a$run("niches")
    a$wait(300)
    expect_identical(a$status$nc_kmeans$status, "done")
    expect_match(a$status$nc_network$summary, "network 'near' from another analysis",
        fixed = TRUE)
    code <- a$code("niches")
    expect_false(grepl("createSpatialNetwork", code, fixed = TRUE))
    expect_match(code, 'spat_network = "near"', fixed = TRUE)
    expect_match(code, "niche_a = paste(", fixed = TRUE)
    expect_true("niche_a" %in% names(v$meta()))
    cols <- priv$group_columns()
    expect_true("analysis:niche_a" %in% cols)
    sch <- priv$schema()
    col <- Find(function(q) q$id == "column",
        Find(function(x) x$id == "groups", sch$steps)$params)
    lab <- Find(function(x) x$value == "analysis:niche_a", col$choices)$label
    expect_identical(lab, "niche_a (Niches)")

    a$set("spatial_network", k = 5, method = "kNN")
    expect_false(identical(priv$keys$nc_network, key0))
    vals <- par("mg_source", "expression_values")
    # The loaded object has raw values only
    expect_identical(vals$value, "raw")
    expect_true("raw" %in% vapply(vals$choices, `[[`, "", "value"))
    a$set("mg_source", expression_values = "raw")
    expect_identical(a$params()$mg_source$expression_values, "raw")
    a$run("markers_groups", step = "mg_source")
    a$wait(120)
    expect_match(a$status$mg_source$summary, "raw values", fixed = TRUE)
    a$set("mg_source", expression_values = "no_such_values")
    a$run("markers_groups", step = "mg_source")
    a$wait(120)
    expect_match(a$status$mg_source$summary, "no_such_values values", fixed = TRUE)
    expect_identical(a$status$mg_groups$status, "blocked")
})

test_that("network steps default to a spatial network of the loaded object", {
    g <- suppressWarnings(suppressMessages(Giotto::createSpatialNetwork(
        lens_analysis_fixture()$g, method = "Delaunay", delaunay_method = "delaunayn_geometry",
        verbose = FALSE)))
    r <- lens_analysis_rig(g = g, analyses = c("interactions", "niches"),
        params = c(lens_analysis_params, list(
            groups = list(column = "object:band"),
            proximity = list(number_of_simulations = 20),
            nc_network = list(network = "new"))), network_dir = NULL)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    priv <- a$.__enclos_env__$private
    expect_identical(priv$values$spatial_network$network, "Delaunay_network")
    expect_identical(priv$values$nc_network$network, "new")
    net <- Find(function(q) q$id == "network",
        Find(function(x) x$id == "spatial_network", priv$schema()$steps)$params)
    expect_identical(net$default, "Delaunay_network")
    a$run("interactions")
    a$wait(300)
    expect_identical(a$status$proximity$status, "done")
    expect_match(a$status$spatial_network$summary, "^Delaunay_network:")
    code <- a$code("interactions")
    expect_false(grepl("createSpatialNetwork", code, fixed = TRUE))
    expect_match(code, 'spatial_network_name = "Delaunay_network"', fixed = TRUE)
})
