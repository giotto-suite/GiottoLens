# ── Generated code ──────────────────────────────────────────────────────────

test_that("Preprocessing code follows the parameters", {
    steps <- .analysis_steps()
    p <- list(resolution = 0.5, n_iterations = 20)
    code <- steps$leiden$code(p, list(network = list(type = "kNN")))
    expect_match(code, 'nn_network_to_use = "kNN", network_name = "kNN.pca"', fixed = TRUE)
    expect_match(code, "resolution = 0.5", fixed = TRUE)
    expect_match(code, 'name = "leiden_clus")', fixed = TRUE)
    code <- steps$leiden$code(c(p, name = "clus_a"), list(network = list(type = "kNN",
        name = "nn_a")))
    expect_match(code, 'network_name = "nn_a"', fixed = TRUE)
    expect_match(code, 'name = "clus_a")', fixed = TRUE)
    expect_identical(steps$labels$code(list(labels = list()), list()), "")
    expect_identical(steps$labels$code(list(labels = list(`1` = "T cell"), name = "ct"),
        list(leiden = list(name = "clus_a"))), paste0('g <- annotateGiotto(g, ',
        'annotation_vector = c("1" = "T cell"), cluster_column = "clus_a", name = "ct")'))
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

# ── Runs ────────────────────────────────────────────────────────────────────

# The steps on the 400 um MERSCOPE vault, against a stand-in viewer
# The tests below run the steps, as jobs, on the analysis fixture
# (helper-analysis.R): 600 cells in three bands, each with ten marker genes.

test_that("an analysis runs nothing until asked, and its keys start at the snapshot", {
    r <- lens_analysis_rig(params = lens_analysis_params, start = FALSE)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    expect_identical(r$v$analysis(), a)
    later::run_now(0.5)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "stale"))
    expect_length(r$v$jobs()$id, 0L)
    expect_null(r$priv$lens_work())
    expect_error(r$v$push_panel(list(mark = "point"), id = "analysis"), "built-in panel")
    expect_match(a$.__enclos_env__$private$keys$filter,
        paste0("<snapshot:", r$priv$snapshot, "$"))
    # The page heard of it, and opens the panel
    sch <- Find(function(m) m$type == "analysis_schema", r$sent())
    expect_true(isTRUE(sch$data$open))

    a$run("preprocess")
    a$wait(300)
    expect_true(all(vapply(a$status, `[[`, "", "status")[names(a$status) != "auto_type"] == "done"))
    expect_match(r$priv$lens_work(), "an analysis")
    expect_error(suppressMessages(r$v$set_object(r$fx$g, feat_type = NULL)), "an analysis")
    suppressMessages(r$v$set_object(r$fx$g, feat_type = NULL, discard = TRUE))
    expect_null(r$priv$lens_analysis)
    expect_false(identical(r$v$analysis(), a))
})

test_that("an analysis's columns sit beside pulled ones, and a gene colors by item key", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    suppressMessages(r$v$pull("band"))
    a$set("umap", min_dist = 0.3)
    a$wait(120)
    expect_true(all(c("band", "umap_1", "leiden_clus") %in% r$priv$meta_names()))
    # A column the analysis no longer makes goes, with rules on it
    r$priv$rule_set <- list(meta = list(kind = "categories", space = "cell_type_auto",
        params = list(values = list("A"))))
    r$priv$own_columns("analysis", r$meta()[c("cell_ID", "qc_pass")])
    expect_false("leiden_clus" %in% r$priv$meta_names())
    expect_true("band" %in% r$priv$meta_names())

    a$handle("analysis_feature", list(step = "markers", feat = "gene03"))
    hit <- NULL
    expect_true(pump_until(function() {
        hit <<- Find(function(m) m$type == "set_color_by", r$sent())
        !is.null(hit)
    }, timeout = 60))
    key <- hit$data$column
    expect_match(key, "^@expression/rna/normalized/analysis%3A[0-9a-f]{16}/gene03$")
    expect_match(hit$data$item$url, "^session/items/")
    vals <- .read_meta_column(r$priv$items_dir(), r$priv$item_files[[key]])
    left <- r$fx$meta$band[match(r$priv$cell_ids, r$fx$meta$cell_ID)] == "A"
    expect_gt(mean(vals[left], na.rm = TRUE), mean(vals[!left], na.rm = TRUE) + 1)
    fb <- Find(function(m) m$type == "analysis_feature", r$sent())
    expect_identical(fb$data$values, "normalized")
    expect_false("gene03" %in% r$priv$meta_names())
    expect_s4_class(a$gobject(), "giotto")
})

test_that("a change reruns only the steps below it", {
    r <- lens_analysis_rig(cell_markers = lens_analysis_fixture()$markers,
        params = c(lens_analysis_params, list(auto_type = list(min_overlap_genes = 2))))
    on.exit(r$done(), add = TRUE)
    a <- r$a
    meta <- r$meta
    a$wait(300)
    st <- vapply(a$status, `[[`, "", "status")
    expect_true(all(st == "done"), info = paste(names(st), st, collapse = ", "))
    expect_setequal(names(r$panels()), c("qc-cells", "qc-feats", "pca-elbow"))
    expect_true(all(c("qc_pass", "umap_1", "umap_2", "leiden_clus", "cell_type",
        "cell_type_auto", "cell_type_auto_score") %in% names(meta())))
    priv <- a$.__enclos_env__$private
    n_cl <- length(unique(stats::na.omit(meta()$leiden_clus)))
    expect_identical(n_cl, 3L)
    expect_identical(nrow(priv$suggestions), n_cl)
    expect_setequal(a$labels(), c("A", "B", "C"))
    expect_match(a$code(), "runPAGEEnrich(g, sign_matrix = sign", fixed = TRUE)
    leiden_before <- a$status$leiden
    a$set("auto_type", method = "hypergeometric")
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_identical(a$status$leiden, leiden_before)
    expect_identical(nrow(meta()), 600L)

    secs <- function() vapply(a$status, function(s) s$secs %||% NA_real_, 1)
    before <- secs()
    a$set("umap", min_dist = 0.3)
    a$wait(120)
    after <- secs()
    expect_identical(after[names(after) != "umap"], before[names(before) != "umap"])

    a$set("filter", min_det_feats_per_cell = 40)
    a$wait(300)
    m <- meta()
    expect_lt(sum(m$qc_pass == "pass"), 600L)
    expect_identical(m$qc_pass == "pass", m$qc_nr_feats >= 40)
    expect_true(all(is.na(m$leiden_clus[m$qc_pass == "removed"])))

    a$set("filter", min_det_feats_per_cell = 70)
    a$wait(300)
    expect_true(all(meta()$qc_pass == "removed"))
    expect_true(all(vapply(a$status[setdiff(names(a$status), c("region", "filter"))],
        `[[`, "", "status") == "blocked"))
    expect_match(a$status$leiden$message, "QC filter")
    expect_false("leiden_clus" %in% names(meta()))
    a$set("filter", min_det_feats_per_cell = 10)
    a$wait(300)
    expect_true(all(vapply(a$status, `[[`, "", "status") == "done"))
    expect_false(anyNA(meta()$leiden_clus))

    a$labels(c(`1` = "first"))
    a$wait(60)
    expect_true("first" %in% meta()$cell_type)
    expect_false("1" %in% names(priv$suggested))
    expect_error(a$set("leiden", resolution = -1), "at least")

    # A region: the steps run on part of the tissue
    region_ids <- utils::head(r$priv$cell_ids, 300)
    a$region(region_ids)
    a$wait(300)
    expect_identical(a$status$region$status, "done")
    expect_match(a$status$region$summary, "300 of 600")
    m <- meta()
    outside <- !m$cell_ID %in% region_ids
    expect_true(all(is.na(m$qc_pass[outside])))
    expect_true(any(!is.na(m$leiden_clus[!outside])))
    expect_match(a$code(), "subsetGiotto", fixed = TRUE)
    a$region(NULL)
    a$wait(300)
    expect_match(a$status$region$summary, "whole tissue")
    r$v$set_selection(character())
    expect_error(a$handle("analysis_region", list(action = "selection")), "select cells first")

    # Saved settings
    a$save_settings("before")
    p_saved <- a$params(); lab_saved <- a$labels()
    a$set("leiden", resolution = 0.3)
    a$wait(120)
    expect_false(identical(a$params(), p_saved))
    a$restore_settings("before")
    a$wait(120)
    expect_identical(a$params(), p_saved)
    expect_identical(a$labels(), lab_saved)
    f <- tempfile(fileext = ".json")
    a$write_settings(f)
    a$remove_settings("before")
    expect_identical(nrow(a$settings()), 0L)
    a$read_settings(f)
    expect_identical(a$settings()$name, "before")
    expect_error(a$restore_settings("nope"), "no saved settings")
})

test_that("a running step is cancelled through its job, and the analysis goes on", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    # A slow job holds the daemon, so the step's job waits behind it
    r$priv$start_job("slow", function(g) { Sys.sleep(5); 1 })
    a$set("umap", min_dist = 0.3)
    expect_true(pump_until(function() identical(a$status$umap$status, "running"), timeout = 30))
    umap_job <- function() r$v$jobs()$id[r$v$jobs()$label == "analysis: UMAP"]
    first <- umap_job()
    expect_length(first, 1L)
    a$cancel()
    expect_true(pump_until(function() !first %in% r$v$jobs()$id, timeout = 15))
    # Preprocessing runs by itself once started: the step runs again
    a$wait(120)
    expect_identical(a$status$umap$status, "done")
})

test_that("Automatic types waits for a marker list", {
    r <- lens_analysis_rig(params = lens_analysis_params)
    on.exit(r$done(), add = TRUE)
    a <- r$a
    a$wait(300)
    expect_identical(a$status$auto_type$status, "blocked")
    expect_match(a$status$auto_type$message, "cell_markers")
    expect_identical(a$status$labels$status, "done")
    expect_false(grepl("runPAGEEnrich", a$code(), fixed = TRUE))
    a$cell_markers(data.frame(type = c("A", "A", "B", "B"),
        gene = c("gene01", "gene02", "gene11", "gene12")))
    a$set("auto_type", min_overlap_genes = 2)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "error")
    expect_match(a$status$auto_type$message, "more than 2")
    a$set("auto_type", min_overlap_genes = 1)
    a$wait(120)
    expect_identical(a$status$auto_type$status, "done")
    expect_true(all(stats::na.omit(r$meta()$cell_type_auto) %in% c("A", "B")))
})
