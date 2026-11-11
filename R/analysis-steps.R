# ── Analysis steps ───────────────────────────────────────────────────────────
#
# The steps of launch_lens_analysis(), as a tree: each step reads the output
# of `input` (NULL = the loaded object; for a `kind = "source"` step, the
# Preprocessing tab's Cell types step or the loaded object, by its `from`
# parameter). `run(g, p)` returns the giotto object
# after the step; `result(g, p, before)` returns what the viewer shows, and
# `stop_below`, a message that blocks the steps below it. `p` holds
# the step's parameter values and `p$up`, the values of its ancestors by step.
# Both run in the worker (adr/0017), so they refer to packages with `::` and to
# the worker helpers `.lens_values()` and `.lens_threads()`.
#
# Each step belongs to an analysis of the catalog (`.analysis_catalog()`).
# Steps of an `auto` analysis run as soon as they are stale; the others run
# when the viewer's Run buttons or `LensAnalysis$run()` ask for them.
#
# A menu parameter's `choices` are list(value = key, label, r = R value); the
# viewer sends the key. `disk = FALSE` choices are left out when the raw
# expression is a GiottoDisk parquetExprStore. A number parameter
# (`type = "number"`) takes any value in [min, max] (whole numbers when
# `integer`); `slider` is the slider's range, `log` a log10 slider. `auto`
# allows an empty value (R `NULL`). A range parameter (`type = "range"`) takes
# consecutive whole numbers `from:to`, at most the PCA components. A column
# parameter (`type = "column"`) names a cell metadata column; its menu lists
# the categorical columns of the object and of the analysis, and an empty
# value takes the first of `cell_type`, `leiden_clus` and the object's columns.
# A text parameter (`type = "text"`) takes any string; `.text_list()` splits
# one on commas.
# A parameter marked by `.view_param()` only changes how a step's result is
# shown: it is left out of the step's key, and a change shows the kept result
# again through the step's `view()`.

.ch <- function(r, label = NULL, value = NULL, disk = TRUE) {
    list(value = value %||% paste(deparse(r), collapse = ""),
        label = label %||% paste(format(r), collapse = " "), r = r, disk = disk)
}

.param <- function(id, label, choices, default) {
    keys <- vapply(choices, `[[`, "", "value")
    if (!default %in% keys) stop("default '", default, "' is not a choice of ", id)
    list(id = id, label = label, type = "choice", choices = choices, default = default)
}

.num_str <- function(x) format(x, scientific = FALSE, digits = 15, trim = TRUE)

.num <- function(id, label, default, slider, min = 0, max = NULL, integer = FALSE,
                 auto = FALSE, step = if (integer) 1 else NULL, log = FALSE) {
    list(id = id, label = label, type = "number", choices = list(),
        default = if (identical(default, "auto")) "auto" else .num_str(default),
        min = min, max = max, integer = integer, auto = auto,
        slider = list(min = slider[[1L]], max = slider[[2L]], step = step, log = log))
}

.view_param <- function(par) {
    par$view <- TRUE
    par
}

.text_param <- function(id, label, default = "", placeholder = "") {
    list(id = id, label = label, type = "text", choices = list(), default = default,
        placeholder = placeholder)
}

# A text value as a character vector: comma-separated, trimmed, empty dropped
.text_list <- function(x) {
    x <- trimws(unlist(strsplit(as.character(x %||% ""), ",", fixed = TRUE)))
    x[nzchar(x)]
}

.col_param <- function(id, label) {
    list(id = id, label = label, type = "column", choices = list(), default = "")
}

.pcs <- function(id, label, default = c(1L, 10L)) {
    list(id = id, label = label, type = "range", choices = list(),
        default = paste0(default[[1L]], ":", default[[2L]]),
        min = 1, max = NULL, integer = TRUE,
        slider = list(min = 1, max = 30, step = 1, log = FALSE))
}

# The key for a value given in R or typed in the viewer; an error if invalid.
# `max_pcs` caps range parameters.
.param_key <- function(par, value, disk = FALSE, max_pcs = NULL) {
    if (identical(par$type, "range")) return(.range_key(value, max_pcs))
    if (identical(par$type, "text")) {
        if (is.null(value)) return("")
        if (!is.character(value) && !is.numeric(value)) stop("must be text", call. = FALSE)
        return(trimws(paste(as.character(value), collapse = ", ")))
    }
    if (identical(par$type, "column")) {
        if (is.null(value)) return("")
        if (!is.character(value) || length(value) != 1L || is.na(value))
            stop("must be one column name", call. = FALSE)
        return(trimws(value))
    }
    if (!identical(par$type, "number")) {
        key <- .value_key(value)
        keys <- vapply(.offered(par$choices, disk), `[[`, "", "value")
        if (!key %in% keys)
            stop("must be one of: ", paste(keys, collapse = ", "), call. = FALSE)
        return(key)
    }
    if (is.null(value) || (is.character(value) && value %in% c("", "auto"))) {
        if (isTRUE(par$auto)) return("auto")
        stop("needs a number", call. = FALSE)
    }
    x <- suppressWarnings(as.numeric(value))
    if (length(x) != 1L || !is.finite(x)) stop("needs a number", call. = FALSE)
    if (isTRUE(par$integer) && x != round(x)) stop("needs a whole number", call. = FALSE)
    if (!is.null(par$min) && x < par$min)
        stop("must be at least ", .num_str(par$min), call. = FALSE)
    if (!is.null(par$max) && x > par$max)
        stop("must be at most ", .num_str(par$max), call. = FALSE)
    .num_str(x)
}

# PCs as "from:to"; one number n is 1:n
.range_key <- function(value, max_pcs = NULL) {
    if (is.character(value) && length(value) == 1L) {
        parts <- strsplit(trimws(value), ":", fixed = TRUE)[[1L]]
        value <- suppressWarnings(as.numeric(parts))
    }
    if (!is.numeric(value) || !length(value) || anyNA(value) || any(value != round(value)))
        stop("needs whole numbers from:to", call. = FALSE)
    if (length(value) == 1L) value <- c(1, value)
    if (length(value) > 2L) {
        if (any(diff(value) != 1)) stop("needs consecutive PCs", call. = FALSE)
        value <- range(value)
    }
    from <- value[[1L]]; to <- value[[2L]]
    if (from < 1) stop("starts at PC 1 or later", call. = FALSE)
    if (to <= from) stop("needs at least 2 PCs (from < to)", call. = FALSE)
    if (!is.null(max_pcs) && to > max_pcs)
        stop("ends after the last PC (", max_pcs, ")", call. = FALSE)
    paste0(.num_str(from), ":", .num_str(to))
}

# The R value behind a key
.param_r <- function(par, key) {
    if (identical(par$type, "range")) {
        b <- as.integer(strsplit(key, ":", fixed = TRUE)[[1L]])
        return(seq.int(b[[1L]], b[[2L]]))
    }
    if (identical(par$type, "column") || identical(par$type, "text")) return(key)
    if (!identical(par$type, "number"))
        return(Find(function(c) identical(c$value, key), par$choices)$r)
    if (identical(key, "auto")) return(NULL)
    x <- as.numeric(key)
    if (isTRUE(par$integer)) as.integer(x) else x
}

.analysis_entry_preprocess <- function() list(
    id = "preprocess", label = "Preprocessing", order = 0, auto = TRUE,
    brief = "QC, normalization, PCA, UMAP, clusters and cell types.",
    description = paste(
        "Filters cells and features, normalizes expression, finds highly variable",
        "features, runs PCA and UMAP, clusters cells with Leiden on a nearest",
        "network, finds marker genes and labels the clusters with cell types.",
        "Each change reruns the step and the steps below it."),
    inputs = c("raw expression", "polygons or spatial locations", "optional: marker gene list"),
    outputs = c("QC values, UMAP coordinates, leiden_clus and cell_type (cell metadata)",
        "QC histograms, HVF and PCA elbow plots", "marker genes per cluster"),
    steps = list(

        region = list(
            label = "Region", input = NULL,
            fun = "subsetGiotto",
            params = list(),
            run = function(g, p) {
                if (!length(p$cells)) return(g)
                GiottoClass::subsetGiotto(g,
                    cell_ids = intersect(p$cells, GiottoClass::spatIDs(g)), verbose = FALSE)
            },
            result = function(g, p, before) {
                n <- length(GiottoClass::spatIDs(g))
                list(summary = if (length(p$cells))
                    sprintf("%d of %d cells (selected region)", n,
                        length(GiottoClass::spatIDs(before)))
                    else sprintf("whole tissue, %d cells", n))
            }
        ),

        filter = list(
            label = "QC filter", input = "region",
            fun = "filterGiotto",
            params = list(
                .num("expression_threshold", "expression threshold", 1, c(0, 10), step = 0.5),
                .num("feat_det_in_min_cells", "feature in min cells", 100, c(0, 500),
                    integer = TRUE),
                .num("min_det_feats_per_cell", "min features per cell", 100, c(0, 300),
                    integer = TRUE)
            ),
            run = function(g, p) {
                out <- Giotto::filterGiotto(g,
                    expression_threshold   = p$expression_threshold,
                    feat_det_in_min_cells  = p$feat_det_in_min_cells,
                    min_det_feats_per_cell = p$min_det_feats_per_cell,
                    verbose = FALSE)
                out
            },
            result = function(g, p, before) {
                feats <- as.data.frame(Giotto::addStatistics(before, expression_values = "raw",
                    detection_threshold = ceiling(p$expression_threshold) - 1,
                    return_gobject = FALSE, verbose = FALSE)$feat_stats)
                by_feat <- Giotto::filterGiotto(before,
                    expression_threshold   = p$expression_threshold,
                    feat_det_in_min_cells  = p$feat_det_in_min_cells,
                    min_det_feats_per_cell = 0, verbose = FALSE)
                cells <- as.data.frame(Giotto::addStatistics(by_feat, expression_values = "raw",
                    detection_threshold = ceiling(p$expression_threshold) - 1,
                    return_gobject = FALSE, verbose = FALSE)$cell_stats)
                kept_cells <- GiottoClass::spatIDs(g)
                kept_feats <- GiottoClass::featIDs(g)
                list(
                    meta = data.frame(cell_ID = as.character(cells$cells),
                        qc_nr_feats = cells$nr_feats, qc_total_expr = cells$total_expr,
                        qc_pass = ifelse(cells$cells %in% kept_cells, "pass", "removed")),
                    feats = data.frame(feat_ID = as.character(feats$feats),
                        nr_cells = feats$nr_cells,
                        kept = feats$feats %in% kept_feats),
                    summary = sprintf("%d of %d cells, %d of %d features",
                        length(kept_cells), nrow(cells), length(kept_feats), nrow(feats)),
                    stop_below = if (length(kept_cells) < 2L || length(kept_feats) < 2L)
                        "too few cells or features pass the QC filter"
                )
            }
        ),

        normalize = list(
            label = "Normalize", input = "filter",
            fun = "normalizeGiotto",
            params = list(
                .param("norm_methods", "method", list(
                    .ch("standard", value = "standard"),
                    .ch("osmFISH", value = "osmFISH", disk = FALSE),
                    .ch("quantile", value = "quantile", disk = FALSE),
                    .ch("pearson_resid", value = "pearson_resid", disk = FALSE)), "standard"),
                .num("scalefactor", "scale factor", 6000, c(100, 1e5), min = 1, log = TRUE),
                .param("log_norm", "log transform",
                    list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE"),
                .param("scale", "z-score scale",
                    list(.ch(TRUE, "yes", disk = FALSE), .ch(FALSE, "no")), "TRUE")
            ),
            run = function(g, p) Giotto::normalizeGiotto(g,
                norm_methods = p$norm_methods, scalefactor = p$scalefactor,
                log_norm = p$log_norm, scale_feats = p$scale, scale_cells = p$scale,
                verbose = FALSE),
            result = function(g, p, before) list(summary = paste0(
                "values used downstream: ", if (isTRUE(p$scale)) "scaled" else "normalized"))
        ),

        hvf = list(
            label = "Highly variable features", input = "normalize",
            fun = "calculateHVF",
            params = list(
                .param("method", "method", list(.ch("cov_groups", value = "cov_groups"),
                    .ch("cov_loess", value = "cov_loess"),
                    .ch("var_p_resid", value = "var_p_resid")), "cov_groups"),
                .num("zscore_threshold", "z-score threshold", 1.5, c(0, 5), step = 0.1),
                .num("difference_in_cov", "difference in cov", 0.1, c(0, 1), step = 0.01),
                .num("var_threshold", "variance threshold", 1, c(0, 5), step = 0.1)
            ),
            run = function(g, p) Giotto::calculateHVF(g, method = p$method,
                zscore_threshold = p$zscore_threshold,
                difference_in_cov = p$difference_in_cov,
                var_threshold = p$var_threshold,
                show_plot = FALSE, return_plot = FALSE, save_plot = FALSE),
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                n <- sum(fm$hvf == "yes")
                list(hvf = fm[intersect(names(fm), c("feat_ID", "mean_expr", "mean_expr_det",
                        "cov", "var", "hvf"))],
                    summary = sprintf("%d of %d features", n, nrow(fm)))
            }
        ),

        pca = list(
            label = "PCA", input = "hvf",
            fun = "runPCA",
            params = list(
                .param("feats_to_use", "features",
                    list(.ch("hvf", "highly variable", value = "hvf"),
                         .ch(NULL, "all", value = "all")), "hvf"),
                .num("ncp", "components", 100, c(2, 100), min = 2, integer = TRUE),
                .param("scale_unit", "scale features",
                    list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE")
            ),
            run = function(g, p) Giotto::runPCA(g,
                expression_values = .lens_values(p), feats_to_use = p$feats_to_use,
                ncp = p$ncp, scale_unit = p$scale_unit),
            result = function(g, p, before) {
                d <- GiottoClass::getDimReduction(g, reduction_method = "pca",
                    name = "pca", output = "dimObj")
                ev <- d@misc$eigenvalues
                list(elbow = data.frame(PC = seq_along(ev), variance = ev / sum(ev)),
                    summary = sprintf("%d components", length(ev)))
            }
        ),

        umap = list(
            label = "UMAP", input = "pca",
            fun = "runUMAP",
            params = list(
                .pcs("dimensions_to_use", "PCs for UMAP"),
                .num("n_neighbors", "neighbors", "auto", c(2, 100), min = 2,
                    integer = TRUE, auto = TRUE),
                .num("min_dist", "min dist", 0.05, c(0, 1), step = 0.01),
                .num("spread", "spread", 1, c(0.1, 5), min = 0.01, step = 0.1)
            ),
            run = function(g, p) Giotto::runUMAP(g,
                expression_values = .lens_values(p),
                dimensions_to_use = p$dimensions_to_use, n_neighbors = p$n_neighbors,
                min_dist = p$min_dist, spread = p$spread, n_threads = .lens_threads()),
            result = function(g, p, before) {
                m <- GiottoClass::getDimReduction(g, reduction_method = "umap",
                    name = "umap", output = "matrix")
                list(meta = data.frame(cell_ID = rownames(m), umap_1 = m[, 1L],
                    umap_2 = m[, 2L]))
            }
        ),

        network = list(
            label = "Nearest network", input = "pca",
            fun = "createNearestNetwork",
            params = list(
                .param("type", "type", list(.ch("sNN", value = "sNN"),
                    .ch("kNN", value = "kNN")), "sNN"),
                .pcs("dimensions_to_use", "PCs for network"),
                .num("k", "k", 30, c(2, 100), min = 2, integer = TRUE),
                .param("engine", "engine", list(.ch("dbscan", "dbscan (exact)", value = "dbscan"),
                    .ch("hnsw", "hnsw (approximate)", value = "hnsw")), "dbscan")
            ),
            run = function(g, p) Giotto::createNearestNetwork(g, type = p$type,
                expression_values = .lens_values(p),
                dimensions_to_use = p$dimensions_to_use, k = p$k, engine = p$engine),
            result = function(g, p, before) list()
        ),

        leiden = list(
            label = "Leiden clusters", input = "network",
            fun = "doLeidenCluster",
            params = list(
                .num("resolution", "resolution", 1, c(0.01, 5), min = 0.001, log = TRUE),
                .num("n_iterations", "iterations", 20, c(1, 200), min = 1, integer = TRUE)
            ),
            run = function(g, p) Giotto::doLeidenCluster(g, nn_network_to_use = p$up$network$type,
                network_name = paste0(p$up$network$type, ".pca"), resolution = p$resolution,
                n_iterations = p$n_iterations, name = "leiden_clus"),
            result = function(g, p, before) {
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                cl <- as.character(cm$leiden_clus)
                lv <- as.character(sort(unique(as.integer(cl))))
                list(meta = data.frame(cell_ID = as.character(cm$cell_ID),
                        leiden_clus = factor(cl, levels = lv)),
                    summary = sprintf("%d clusters", length(lv)))
            }
        ),

        markers = list(
            label = "Markers", input = "leiden",
            fun = "findMarkers_one_vs_all",
            params = list(
                .param("method", "method", list(.ch("scran", value = "scran"),
                    .ch("gini", value = "gini")), "scran"),
                .num("top", "markers shown", 5, c(1, 20), min = 1, max = 50, integer = TRUE)
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                m <- as.data.frame(Giotto::findMarkers_one_vs_all(g,
                    expression_values = .lens_values(p), cluster_column = "leiden_clus",
                    method = p$method, verbose = FALSE))
                rank_col <- if (p$method == "gini") "comb_rank" else "Top"
                score_col <- if (p$method == "gini") "comb_score" else "logFC"
                m <- m[order(m$cluster, m[[rank_col]]), ]
                m <- do.call(rbind, lapply(split(m, m$cluster), utils::head, p$top))
                list(markers = data.frame(cluster = as.character(m$cluster),
                    feat = as.character(m$feats), score = m[[score_col]]))
            }
        ),

        auto_type = list(
            label = "Automatic types", input = "leiden",
            fun = "runPAGEEnrich",
            params = list(
                .param("method", "method", list(.ch("PAGE", value = "PAGE"),
                    .ch("hypergeometric", value = "hypergeometric")), "PAGE"),
                .num("min_overlap_genes", "min overlap genes (PAGE)", 5, c(0, 20),
                    min = 0, integer = TRUE),
                .num("top_percentage", "top % expressed (hypergeometric)", 5, c(1, 50),
                    min = 0.1, max = 100, step = 0.5)
            ),
            run = function(g, p) {
                feats <- GiottoClass::featIDs(g)
                mk <- lapply(p$cell_markers, intersect, feats)
                if (p$method == "PAGE") {
                    mk <- mk[lengths(mk) > p$min_overlap_genes]
                    if (!length(mk)) stop("no cell type has more than ", p$min_overlap_genes,
                        " of its marker genes in the panel (min overlap genes)")
                } else {
                    mk <- mk[lengths(mk) > 0L]
                    if (!length(mk)) stop("no marker gene is in the panel")
                }
                sm <- Giotto::makeSignMatrixPAGE(sign_names = names(mk), sign_list = mk)
                rev_log <- isTRUE(p$up$normalize$log_norm) && !isTRUE(p$up$normalize$scale)
                if (p$method == "PAGE") {
                    Giotto::runPAGEEnrich(g, sign_matrix = sm, expression_values = .lens_values(p),
                        min_overlap_genes = p$min_overlap_genes, reverse_log_scale = rev_log,
                        name = "lens_auto", verbose = FALSE)
                } else {
                    Giotto::runHyperGeometricEnrich(g, sign_matrix = sm,
                        expression_values = .lens_values(p), top_percentage = p$top_percentage,
                        reverse_log_scale = rev_log, name = "lens_auto")
                }
            },
            result = function(g, p, before) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g, name = "lens_auto",
                    output = "data.table"))
                types <- setdiff(names(e), "cell_ID")
                m <- as.matrix(e[types])
                best <- types[max.col(m, ties.method = "first")]
                score <- apply(m, 1L, max)
                if (p$method != "PAGE") best[score <= 0] <- NA_character_
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                cl <- as.character(cm$leiden_clus[match(e$cell_ID, cm$cell_ID)])
                sug <- do.call(rbind, lapply(sort(unique(cl)), function(k) {
                    rows <- cl == k
                    means <- colMeans(m[rows, , drop = FALSE])
                    type <- names(means)[which.max(means)]
                    data.frame(cluster = k, type = type,
                        share = round(mean(best[rows] == type, na.rm = TRUE), 2),
                        n = sum(rows))
                }))
                missing <- setdiff(names(p$cell_markers), types)
                list(
                    meta = data.frame(cell_ID = as.character(e$cell_ID),
                        cell_type_auto = best, cell_type_auto_score = score),
                    suggest = sug,
                    summary = paste0(length(types), " of ", length(p$cell_markers),
                        " cell types scored",
                        if (length(missing)) paste0("; too few panel genes: ",
                            paste(missing, collapse = ", ")))
                )
            }
        ),

        labels = list(
            label = "Cell types", input = "leiden",
            fun = "annotateGiotto",
            params = list(),
            run = function(g, p) {
                cl <- as.character(sort(unique(as.integer(
                    GiottoClass::pDataDT(g)$leiden_clus))))
                lab <- vapply(cl, function(k) {
                    v <- p$labels[[k]]
                    if (is.null(v) || !nzchar(v)) k else v
                }, "")
                Giotto::annotateGiotto(g, annotation_vector = stats::setNames(lab, cl),
                    cluster_column = "leiden_clus", name = "cell_type")
            },
            result = function(g, p, before) {
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                list(meta = data.frame(cell_ID = as.character(cm$cell_ID),
                    cell_type = as.character(cm$cell_type)))
            }
        )
    )
)
