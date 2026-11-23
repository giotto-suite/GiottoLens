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
    net <- .schema_par(sch, "nc_network", "network")
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
    col <- .schema_par(sch, "groups", "column")
    lab <- Find(function(x) x$value == "analysis:niche_a", col$choices)$label
    expect_identical(lab, "niche_a (Niches)")

    a$set("spatial_network", k = 5, method = "kNN")
    expect_false(identical(priv$keys$nc_network, key0))
    vals <- .schema_par(sch, "mg_source", "expression_values")
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
    net <- .schema_par(priv$schema(), "spatial_network", "network")
    expect_identical(net$default, "Delaunay_network")
    a$run("interactions")
    a$wait(300)
    expect_identical(a$status$proximity$status, "done")
    expect_match(a$status$spatial_network$summary, "^Delaunay_network:")
    code <- a$code("interactions")
    expect_false(grepl("createSpatialNetwork", code, fixed = TRUE))
    expect_match(code, 'spatial_network_name = "Delaunay_network"', fixed = TRUE)
})
