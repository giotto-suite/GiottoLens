# Saved selections are named rule sets R holds for the object shown (adr/0029);
# comparing two runs Giotto::findScranMarkers() as a job (R/selections.R,
# adr/0020).

test_that("saved selections keep the rules, and bring them back as they were", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    suppressMessages(v$push_metadata(fx$meta))
    expect_error(v$save_selection("a"), "no rules to save")
    v$select(lens_range("score", 3, 6), source = "hist:score")
    v$select(lens_categories("leiden_clus", "a"), source = "scatter", replace = FALSE, combine = "or")
    sel <- v$selection
    expect_setequal(v$save_selection("a"), sel)
    v$select(NULL)
    v$save_selection(" b ", lens_cells("cell_010"))
    expect_identical(v$selections(), data.frame(name = c("a", "b"), rules = c(2L, 1L),
        cells = c(length(sel), 1L)))
    expect_identical(v$selections("b"), "cell_010")

    # Restored: the same rules under their own sources, and their mode
    v$select(NULL, combine = "and")
    v$restore_selection("a")
    expect_identical(v$rules()$source, c("hist:score", "scatter"))
    expect_setequal(v$selection, sel)
    expect_identical(lens_priv(v)$combine, "or")
    # Edited after, the saved one stays as it was
    v$select(lens_range("score", 9, 10), source = "hist:score", replace = FALSE)
    expect_identical(v$selections()$cells[1L], length(sel))

    # Renamed in place; never onto another's name
    v$rename_selection("a", " a2 ")
    expect_identical(v$selections()$name, c("a2", "b"))
    expect_error(v$rename_selection("a2", "b"), "already named 'b'")
    expect_error(v$rename_selection("z", "y"), "no saved selection 'z'")
    v$rename_selection("a2", "a")

    v$remove_selection("a")
    expect_identical(v$selections()$name, "b")
    expect_error(v$selections("a"), "no saved selection 'a'; saved: b")
    expect_error(v$save_selection(""), "non-empty string")

    # Comparing needs two saved selections and an object with expression
    v$save_selection("c", lens_cells(c("cell_003", "cell_004")))
    expect_error(v$compare_selections("b", "b"), "the same saved selection")
    expect_error(v$compare_selections("b", "z"), "no saved selection 'z'")
    expect_error(v$compare_selections("b", "c"), "shows layers, not a giotto object")
    expect_identical(nrow(v$de_results()), 0L)
})

test_that("a comparison reads normalized values, and saved selections go with the object", {
    fx <- lens_bins_fixture()
    v <- suppressMessages(launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE))
    on.exit(v$close(), add = TRUE)
    v$save_selection("left", lens_cells(fx$xy$cell_ID[1:10]))
    expect_error(v$compare_selections("left"), "no 'normalized' expression; normalize .*available: raw")
    expect_error(v$compare_selections("left", values = "nope"), "no 'nope' expression; available: raw")
    expect_error(suppressMessages(v$set_object(fx$g, spat_unit = "bin", feat_type = NULL)), "1 saved selection")
    suppressMessages(v$set_object(fx$g, spat_unit = "bin", feat_type = NULL, discard = TRUE))
    expect_identical(nrow(v$selections()), 0L)
})

test_that("saved selections are compared in a job, docked as a volcano plot", {
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    v$save_selection("left", lens_cells(dv$d$left))
    v$save_selection("right", lens_cells(dv$d$right))
    tab <- suppressMessages(v$compare_selections("left", "right"))
    expect_named(tab, c("gene", "logFC", "p_value", "FDR"))
    expect_identical(tab$gene[1L], "g1")
    expect_gt(tab$logFC[1L], 0)
    expect_false(is.unsorted(tab$FDR, na.rm = TRUE))

    # The same test run directly
    g <- dv$d$g
    ids <- GiottoClass::spatIDs(g, spat_unit = "bin")
    ref <- GiottoClass::addCellMetadata(g, spat_unit = "bin", feat_type = "rna",
        new_metadata = data.frame(cell_ID = ids, grp = ifelse(ids %in% dv$d$left, "l", "r")),
        by_column = TRUE, column_cell_ID = "cell_ID")
    ref <- suppressMessages(Giotto::findScranMarkers(ref, spat_unit = "bin", feat_type = "rna",
        expression_values = "normalized", cluster_column = "grp", group_1 = "l", group_2 = "r",
        verbose = FALSE))
    ref <- as.data.frame(Find(function(d) d$cluster[1L] == "l", ref))
    m <- match(tab$gene, ref$feats)
    expect_equal(tab$logFC, ref$summary.logFC[m])
    expect_equal(tab$FDR, ref$FDR[m])

    res <- v$de_results()
    expect_identical(res$id, "de-1")
    expect_identical(res$cells_a, length(dv$d$left))
    expect_identical(res$values, "normalized")
    expect_true("de-1" %in% v$panels()$id)
    expect_identical(v$de_results("de-1"), tab)

    # Against every other cell, without waiting: the job's id
    id <- v$compare_selections("left", wait = FALSE)
    expect_identical(v$jobs()$label, "DE left vs rest")
    expect_identical(v$jobs()$id, id)
    expect_true(suppressMessages(pump_until(function() nrow(v$de_results()) == 2L, timeout = 60)))
    expect_identical(v$de_results()$b, c("right", "rest"))
})

test_that("the page acts on saved selections through the `selection` ask, and a volcano pick colors its cells", {
    skip_if_not_installed("websocket")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    a <- ws_client(ws_url(v), load = dv$priv$load_seq)
    on.exit(a$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() v$connected()))
    expect_true(pump_until(function() length(ws_msgs(a, "selections")) > 0L))

    v$set_selection(dv$d$left)
    ws_ask(a, "1", op = "selection", action = "save", name = "left")
    expect_identical(ws_answer(a, "1", timeout = 60)$data$cells, length(dv$d$left))
    expect_true(isTRUE(utils::tail(ws_msgs(a, "selections"), 1L)[[1L]]$data$open))
    v$select(NULL)
    ws_ask(a, "2", op = "selection", action = "save", name = "empty")
    expect_match(ws_answer(a, "2", timeout = 60)$error, "no rules to save")
    ws_ask(a, "2b", op = "selection", action = "restore", name = "left")
    expect_true(!is.null(ws_answer(a, "2b", timeout = 60)$data))
    expect_setequal(v$selection, dv$d$left)
    ws_ask(a, "3", op = "selection", action = "compare", a = "left", b = "", ref = "p1")
    r <- suppressMessages(ws_answer(a, "3", timeout = 60))
    expect_identical(r$data$id, "de-1")
    expect_true(any(vapply(ws_msgs(a, "job"), function(m) identical(m$data$ref, "p1"), NA)))

    # A click on g1 in the volcano plot: that page colours its cells by it
    ws_say(a, "panel_pick", list(id = "de-1", value = list(gene = list("g1"))))
    key <- .item_key("expression", "rna", "g1", name = "normalized")
    expect_true(pump_until(function() any(vapply(ws_msgs(a, "set_color_by"), function(m)
        identical(m$data$column, key), NA)), timeout = 60))
    hit <- Find(function(m) identical(m$data$column, key), ws_msgs(a, "set_color_by"))
    expect_match(hit$data$item$url, "^session/items/")
    expect_false("g1" %in% dv$priv$meta_names())
})
