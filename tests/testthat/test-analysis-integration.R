mini_vault <- "/Users/jeffreysheridan/Documents/Projects/GiottoDev/vaults/render_mini_20261103/giotto_project"

# A stand-in viewer that records what the analysis sends
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

# Ids of the tables last sent to the viewer
.sent_tables <- function(v) {
    tb <- Filter(function(m) m$type == "analysis_tables", v$sent)
    if (!length(tb)) return(character())
    x <- tb[[length(tb)]]$data$tables
    unlist(lapply(x, function(t) vapply(t, `[[`, "", "id")), use.names = FALSE)
}

.colon_markers <- list(
    Epithelial = c("EPCAM", "KRT20", "CDX2", "MUC2"),
    Fibroblast = c("COL1A2", "COL3A1", "LUM", "PDGFRA", "FAP"),
    Immune = c("PTPRC", "CD3E", "CD3D", "CD2", "CD4", "CD8A", "MS4A1", "CD68"),
    Endothelial = c("PECAM1", "VWF", "CDH5"),
    `Smooth muscle` = c("ACTA2", "DES", "MYH11"),
    Absent = c("NOTAGENE1", "NOTAGENE2"))

test_that("Harmony and enrichment entries have their fields and steps", {
    cat <- .analysis_catalog()
    expect_true(all(c("harmony", "enrichment") %in% names(cat)))
    h <- cat$harmony
    expect_identical(h$label, "Integration (Harmony)")
    expect_identical(h$order, 90)
    expect_false(h$auto)
    expect_identical(names(h$steps),
        c("hm_source", "hm_batch", "hm_harmony", "hm_network", "hm_leiden", "hm_umap"))
    expect_identical(h$steps$hm_source$kind, "source")
    expect_identical(h$steps$hm_batch$kind, "groups")
    expect_identical(h$steps$hm_umap$input, "hm_harmony")
    e <- cat$enrichment
    expect_identical(e$label, "Cell type enrichment")
    expect_identical(e$order, 100)
    expect_identical(names(e$steps), c("en_source", "en_markers", "en_enrich"))
    expect_true(isTRUE(e$steps$en_markers$markers) && isTRUE(e$steps$en_enrich$markers))
    meth <- vapply(e$steps$en_enrich$params[[1L]]$choices, `[[`, "", "value")
    expect_identical(meth, c("PAGE", "hypergeometric"))
    for (ent in list(h, e)) for (s in names(ent$steps)) {
        expect_true(startsWith(s, if (ent$id == "harmony") "hm_" else "en_"), info = s)
        expect_true(is.function(ent$steps[[s]]$code), info = s)
    }
})

test_that("Harmony and enrichment steps write their R code", {
    h <- .analysis_catalog()$harmony$steps
    up <- list(hm_batch = list(column_name = "x_half"))
    expect_identical(h$hm_harmony$code(list(dimensions_to_use = 1:10), up),
        paste0("g <- runGiottoHarmony(g, vars_use = \"x_half\", dim_reduction_to_use = ",
            "\"pca\", dimensions_to_use = 1:10, name = \"harmony\")"))
    expect_match(h$hm_network$code(list(type = "sNN", dimensions_to_use = 1:8, k = 20L), up),
        "dimensions_to_use = 1:8, k = 20, name = \"sNN.harmony\"", fixed = TRUE)
    up$hm_network <- list(type = "kNN")
    expect_match(h$hm_leiden$code(list(resolution = 0.5, n_iterations = 20L), up),
        "nn_network_to_use = \"kNN\", network_name = \"kNN.harmony\", resolution = 0.5",
        fixed = TRUE)
    um <- h$hm_umap$code(list(dimensions_to_use = 1:10, n_neighbors = NULL, min_dist = 0.05,
        spread = 1), up)
    expect_false(grepl("n_neighbors", um, fixed = TRUE))
    expect_match(um, "min_dist = 0.05, spread = 1", fixed = TRUE)

    e <- .analysis_catalog()$enrichment$steps
    expect_match(e$en_markers$code(list(), list()), "makeSignMatrixPAGE", fixed = TRUE)
    p <- list(method = "PAGE", min_overlap_genes = 2L, top_percentage = 5,
        reverse_log_scale = TRUE, output_enrichment = "original")
    expect_identical(e$en_enrich$code(p, list()),
        paste0("g <- runPAGEEnrich(g, sign_matrix = sign, min_overlap_genes = 2, ",
            "reverse_log_scale = TRUE, output_enrichment = \"original\", name = \"PAGE\")"))
    p$method <- "hypergeometric"; p$top_percentage <- 10
    expect_match(e$en_enrich$code(p, list()), "runHyperGeometricEnrich(g, sign_matrix = sign, top_percentage = 10",
        fixed = TRUE)
})

test_that("Harmony integrates two halves of the field", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not_installed("harmony")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    sl <- GiottoClass::getSpatialLocations(g, output = "data.table")
    half <- data.table::data.table(cell_ID = sl$cell_ID,
        x_half = ifelse(sl$sdimx < stats::median(sl$sdimx), "left", "right"))
    g <- GiottoClass::addCellMetadata(g, new_metadata = half, by_column = TRUE,
        column_cell_ID = "cell_ID")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "harmony", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        hm_source = list(from = "object"),
        hm_batch = list(column = "object:x_half")))
    on.exit(a$close(), add = TRUE)
    hs <- c("hm_source", "hm_batch", "hm_harmony", "hm_network", "hm_leiden", "hm_umap")
    st <- function() vapply(a$status[hs], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("harmony")
    a$wait(300)
    expect_true(all(st() == "done"), info = paste(st(), collapse = " "))
    expect_match(a$status$hm_batch$summary, "2 batches (x_half)", fixed = TRUE)
    expect_true(all(c("hm_leiden", "hm_umap_1", "hm_umap_2") %in% names(v$meta)))
    expect_gt(length(unique(stats::na.omit(v$meta$hm_leiden))), 1L)
    expect_identical(sum(!is.na(v$meta$hm_umap_1)), length(GiottoClass::spatIDs(g)))
    expect_true(all(c("hm_mix", "hm_umap") %in% names(v$panels)))
    expect_identical(v$panels$hm_mix$mark$type, "bar")
    expect_setequal(unique(v$panels$hm_umap$data$values$batch), c("left", "right"))
    expect_true("hm_mix_table" %in% .sent_tables(v))
    expect_identical(nrow(a$history("harmony")), 1L)
    code <- a$code("harmony")
    expect_match(code, "runGiottoHarmony(g, vars_use = \"x_half\"", fixed = TRUE)
    message("harmony secs: ", paste(hs, vapply(a$status[hs], function(s)
        format(s$secs %||% NA), ""), sep = "=", collapse = ", "))

    secs <- a$status$hm_harmony$secs
    a$set("hm_leiden", resolution = 0.5)
    a$wait(30)
    expect_identical(unname(st()), c("done", "done", "done", "done", "stale", "done"))
    expect_identical(a$status$hm_harmony$secs, secs)
    expect_identical(nrow(a$history("harmony")), 1L)

    left <- half$cell_ID[half$x_half == "left"]
    a$region(left)
    a$wait(300)
    a$run("harmony")
    a$wait(300)
    expect_identical(a$status$hm_batch$status, "done")
    expect_identical(a$status$hm_harmony$status, "blocked")
    expect_match(a$status$hm_harmony$message, "has one value", fixed = TRUE)
})

test_that("Cell type enrichment scores cells for a marker list", {
    skip_on_cran()
    skip_if_not_installed("callr")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
    skip_if_not(dir.exists(mini_vault), "mini vault not found")
    g <- GiottoDisk::snapshotLoad(mini_vault, name = "clustered")
    v <- .fake_viewer()
    a <- LensAnalysis$new(v, g, analyses = "enrichment", params = list(
        filter = list(feat_det_in_min_cells = 10, min_det_feats_per_cell = 20),
        en_source = list(from = "object"),
        en_enrich = list(min_overlap_genes = 2)))
    on.exit(a$close(), add = TRUE)
    es <- c("en_source", "en_markers", "en_enrich")
    st <- function() vapply(a$status[es], `[[`, "", "status")
    a$wait(300)
    expect_true(all(st() == "stale"))

    a$run("enrichment")
    a$wait(120)
    expect_identical(unname(st()), c("done", "done", "blocked"))
    expect_match(a$status$en_enrich$message, "no marker list", fixed = TRUE)

    a$cell_markers(.colon_markers)
    a$wait(30)
    expect_identical(unname(st()[2:3]), c("stale", "stale"))
    a$run("enrichment")
    a$wait(300)
    expect_true(all(st() == "done"), info = paste(st(), collapse = " "))
    expect_match(a$status$en_enrich$summary, "5 of 6 cell types scored (PAGE); too few panel genes: Absent",
        fixed = TRUE)
    cols <- c("en_Epithelial", "en_Fibroblast", "en_Immune", "en_Endothelial",
        "en_Smooth_muscle", "en_best")
    expect_true(all(cols %in% names(v$meta)))
    expect_true(all(stats::na.omit(v$meta$en_best) %in% names(.colon_markers)))
    expect_true(is.numeric(v$meta$en_Epithelial))
    expect_true(all(c("en_genes", "en_cluster_table") %in% .sent_tables(v)))
    spec <- v$panels$en_clusters
    expect_identical(spec$mark$type, "rect")
    n_clus <- length(unique(GiottoClass::pDataDT(g)$leiden_clus))
    expect_identical(nrow(spec$data$values), as.integer(n_clus * 5L))
    fields <- c(spec$encoding$x$field, spec$encoding$y$field, spec$encoding$color$field,
        vapply(spec$encoding$tooltip, `[[`, "", "field"))
    expect_true(all(fields %in% names(spec$data$values)))
    expect_false(any(grepl(".", fields, fixed = TRUE)))
    expect_identical(nrow(a$history("enrichment")), 2L)
    expect_match(a$code("enrichment"), "runPAGEEnrich(g, sign_matrix = sign, min_overlap_genes = 2",
        fixed = TRUE)
    message("enrichment secs: ", paste(es, vapply(a$status[es], function(s)
        format(s$secs %||% NA), ""), sep = "=", collapse = ", "))

    a$set("en_enrich", method = "hypergeometric")
    a$wait(30)
    expect_identical(unname(st()), c("done", "done", "stale"))
    expect_identical(nrow(a$history("enrichment")), 2L)
    a$run("enrichment")
    a$wait(300)
    expect_identical(a$status$en_enrich$status, "done")
    expect_match(a$status$en_enrich$summary, "(hypergeometric)", fixed = TRUE)
    expect_identical(nrow(a$history("enrichment")), 3L)
    message("enrichment hypergeometric secs: ", format(a$status$en_enrich$secs))
})
