test_that("Interaction-changed genes defaults and code follow the parameters", {
    st <- .analysis_entry_icf()$steps
    tests <- .par(st$icf_test, "diff_test")
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

test_that("Interaction-changed genes fill a gene table", {
    r <- lens_analysis_rig(analyses = "icf", params = c(lens_analysis_params, list(
        icf_source = list(from = "object"),
        icf_groups = list(column = "object:band"),
        icf_test = list(nr_permutations = 5, adjust_method = "none"))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    v <- r
    ist <- c("icf_source", "icf_groups", "icf_network", "icf_test")
    st <- function() step_status(a, ist)
    a$wait(300)
    expect_true(all(st() == "stale"))
    priv <- a$.__enclos_env__$private
    sch <- priv$schema()
    dt <- .schema_par(sch, "icf_test", "diff_test")
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
    st <- function() step_status(a, ist)
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
