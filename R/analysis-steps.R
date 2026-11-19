# ── Analysis steps ───────────────────────────────────────────────────────────
#
# The steps of viewer$analysis(), as a tree: each step reads the output
# of `input` (NULL = the loaded object; for a `kind = "source"` step, the
# Preprocessing tab's Cell types step or the loaded object, by its `from`
# parameter). `run(g, p)` returns the giotto object
# after the step; `result(g, p, before)` returns what the viewer shows, and
# `stop_below`, a message that blocks the steps below it. `p` holds
# the step's parameter values and `p$up`, the values of its ancestors by step.
# Both run in the worker (adr/0021), so they refer to packages with `::` and to
# the worker helpers `.lens_values(p)` (see `.values_of()`), `.lens_threads()`, `.lens_progress(done,
# total, what)` (progress shown under the running step), `.lens_note(text)`
# (added to the step's summary), `.lens_keep(x)` and `.lens_kept()` (values
# `run()` keeps for `result()`), `.lens_count_calls(expr, ns, fun, total, what)`
# (calls of a function as progress), `.lens_silhouette(d, cl)` (mean silhouette
# width) and `.lens_network(g, params, create)` (a saved spatial network).
# Progress of Giotto functions that use progressr is shown too.
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
# A values parameter (`type = "values"`) names expression values; its menu
# lists the values of the object for the spatial unit and feature type, and
# those of the Normalize step when the step reads the Preprocessing tab. An
# empty value takes the first of `prefer` the menu lists, else the first
# entry. `.values_of(p, up)` is the value of the step's values parameter, else
# that of the nearest step above with one.
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

.values_param <- function(prefer = "normalized", id = "expression_values",
                          label = "expression values") {
    list(id = id, label = label, type = "values", choices = list(), default = "",
        prefer = prefer)
}

# The name a step stores its result under (`type = "text"`); empty takes
# Giotto's default, shown as `placeholder`
.name_param <- function(default = "", placeholder = default, id = "name", label = "name")
    .text_param(id, label, default = default, placeholder = placeholder)

# Names of the Preprocessing results: PCA, UMAP, nearest network, Leiden
# column, enrichment and cell type column. `up` holds the values of the
# Preprocessing steps by step (missing steps take the defaults).
.pre_names <- function(up) {
    or <- function(x, default) if (is.character(x) && length(x) == 1L && nzchar(x)) x
        else default
    list(
    pca = or(up$pca$name, "pca"),
    umap = or(up$umap$name, "umap"),
    network = or(up$network$name, paste0(up$network$type %||% "sNN", ".pca")),
    leiden = or(up$leiden$name, "leiden_clus"),
    auto_type = or(up$auto_type$name, up$auto_type$method %||% "PAGE"),
    labels = or(up$labels$name, "cell_type"))
}

# The expression values a step reads: its own values parameter, else that of
# the nearest step above it in `up`
.values_of <- function(p, up = p$up) {
    v <- p$expression_values
    if (is.character(v) && length(v) == 1L && nzchar(v)) return(v)
    for (a in up) {
        v <- a$expression_values
        if (is.character(v) && length(v) == 1L && nzchar(v)) return(v)
    }
    "normalized"
}

.pcs <- function(id, label, default = c(1L, 10L)) {
    list(id = id, label = label, type = "range", choices = list(),
        default = paste0(default[[1L]], ":", default[[2L]]),
        min = 1, max = NULL, integer = TRUE,
        slider = list(min = 1, max = 30, step = 1, log = FALSE))
}

# A logical parameter
.yes_no <- function(id, label, default = TRUE)
    .param(id, label, list(.ch(TRUE, "yes"), .ch(FALSE, "no")),
        if (isTRUE(default)) "TRUE" else "FALSE")

# set_seed and seed_number, advanced
.seed_params <- function() list(
    .advanced(.yes_no("set_seed", "set seed")),
    .advanced(.num("seed_number", "seed", 1234, c(1, 10000), min = 0, integer = TRUE)))

# Help for .seed_params(); `what` names the random part of the step
.seed_help <- function(what) list(
    set_seed = paste0(
        "Whether a fixed seed is set before ", what, ", so the same settings give the same ",
        "result each time. With no, each run can differ slightly."),
    seed_number = paste0(
        "The seed set before ", what, " when set seed is yes. Another number gives another, ",
        "equally valid, random result; the same number repeats it."))

# A value as R code
.code_value <- function(v) {
    if (is.integer(v) && length(v) == 1L) v <- as.numeric(v)
    paste(deparse(v), collapse = "")
}

# The key of a parameter's R value
.r_key <- function(par, v) {
    if (identical(par$type, "choice")) {
        ch <- Find(function(c) identical(c$r, v), par$choices)
        if (!is.null(ch)) return(ch$value)
    }
    .value_key(v)
}

# "argument = value" for the parameters `ids` of a step, in that order. Names
# of `ids` are the Giotto arguments (unnamed: the parameter id). A parameter
# with value NULL is left out; an advanced parameter is left out when its
# value is its default (`par$code_default` when set, else the R value of
# `par$default`); a parameter hidden by its show_if, or by `show` (show_if by
# parameter id), is left out.
.code_args <- function(params, p, ids, show = list()) {
    args <- names(ids) %||% rep("", length(ids))
    args[!nzchar(args)] <- ids[!nzchar(args)]
    keys <- list()
    for (par in params) keys[[par$id]] <- .r_key(par, p[[par$id]])
    out <- character()
    for (i in seq_along(ids)) {
        par <- Find(function(q) identical(q$id, ids[[i]]), params)
        if (is.null(par)) next
        if (!is.null(show[[par$id]])) par$show_if <- show[[par$id]]
        if (!.param_shown(par, keys)) next
        v <- p[[par$id]]
        if (isTRUE(par$advanced)) {
            def <- if ("code_default" %in% names(par)) par$code_default
                else .param_r(par, par$default)
            if (identical(.code_value(v), .code_value(def))) next
        }
        if (is.null(v)) next
        out <- c(out, paste0(args[[i]], " = ", .code_value(v)))
    }
    out
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
    if (identical(par$type, "spatial_network")) {
        if (is.null(value) || identical(value, "")) return("new")
        if (!is.character(value) || length(value) != 1L || is.na(value))
            stop("must be one network name or \"new\"", call. = FALSE)
        return(trimws(value))
    }
    if (identical(par$type, "values")) {
        if (is.null(value)) return("")
        if (!is.character(value) || length(value) != 1L || is.na(value))
            stop("must be one expression name", call. = FALSE)
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
    if (par$type %in% c("column", "text", "values", "spatial_network")) return(key)
    if (!identical(par$type, "number"))
        return(Find(function(c) identical(c$value, key), par$choices)$r)
    if (identical(key, "auto")) return(NULL)
    x <- as.numeric(key)
    if (isTRUE(par$integer)) as.integer(x) else x
}

# Parameters of the Preprocessing steps, by step
.preprocess_params <- function() {
    factominer <- requireNamespace("FactoMineR", quietly = TRUE)
    nndescent <- requireNamespace("rnndescent", quietly = TRUE)
    list(
        filter = list(
            .num("expression_threshold", "expression threshold", 1, c(0, 10), step = 0.5),
            .num("feat_det_in_min_cells", "feature in min cells", 100, c(0, 500),
                integer = TRUE),
            .num("min_det_feats_per_cell", "min features per cell", 100, c(0, 300),
                integer = TRUE)
        ),
        normalize = list(
            .param("norm_methods", "method", list(
                .ch("standard", value = "standard"),
                .ch("osmFISH", value = "osmFISH", disk = FALSE),
                .ch("quantile", value = "quantile", disk = FALSE),
                .ch("pearson_resid", value = "pearson_resid", disk = FALSE)), "standard"),
            .param("log_norm", "log transform",
                list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE"),
            .param("scale", "z-score scale",
                list(.ch(TRUE, "yes", disk = FALSE), .ch(FALSE, "no")), "TRUE"),
            .advanced(.yes_no("library_size_norm", "library size normalization")),
            .advanced(.num("scalefactor", "scale factor", 6000, c(100, 1e5), min = 1,
                log = TRUE)),
            .advanced(.num("logbase", "log base", 2, c(1.5, 10), min = 1.0001, step = 0.5)),
            .advanced(.param("scale_order", "scale order", list(
                .ch("first_feats", "features first", value = "first_feats"),
                .ch("first_cells", "cells first", value = "first_cells")), "first_feats")),
            .advanced(.num("theta", "theta", 100, c(1, 1000), min = 0.001, log = TRUE))
        ),
        hvf = c(list(
            .values_param("normalized"),
            .param("method", "method", list(.ch("cov_groups", value = "cov_groups"),
                .ch("cov_loess", value = "cov_loess"),
                .ch("var_p_resid", value = "var_p_resid")), "cov_groups"),
            .num("zscore_threshold", "z-score threshold", 1.5, c(0, 5), step = 0.1),
            .num("difference_in_cov", "difference in cov", 0.1, c(0, 1), step = 0.01),
            .num("var_threshold", "variance threshold", 1, c(0, 5), step = 0.1),
            .advanced(.num("n_top_feats", "max features", 2000, c(10, 5000), min = 1,
                integer = TRUE, log = TRUE)),
            .advanced(.num("expression_threshold", "detection threshold", 0, c(0, 5),
                step = 0.1)),
            .advanced(.num("nr_expression_groups", "expression groups", 20, c(2, 50),
                min = 1, integer = TRUE)),
            .advanced(.num("theta", "theta", 100, c(1, 1000), min = 0.001, log = TRUE)),
            .advanced(.param("reverse_log_scale", "reverse log scale",
                list(.ch(TRUE, "yes", disk = FALSE), .ch(FALSE, "no")), "FALSE")),
            .advanced(.num("logbase", "log base", 2, c(1.5, 10), min = 1.0001, step = 0.5)),
            .advanced(.num("random_subset", "random subset of cells", "auto", c(100, 100000),
                min = 2, integer = TRUE, auto = TRUE, log = TRUE)),
            .advanced(.yes_no("calc_gini", "Gini index", FALSE))),
            .seed_params()),
        pca = c(list(
            .values_param(c("scaled", "normalized")),
            .param("feats_to_use", "features",
                list(.ch("hvf", "highly variable", value = "hvf"),
                     .ch(NULL, "all", value = "all")), "hvf"),
            .num("ncp", "components", 100, c(2, 100), min = 2, integer = TRUE),
            .param("scale_unit", "scale features",
                list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE"),
            .advanced(.yes_no("center", "center features")),
            .advanced(.param("method", "method", c(list(
                .ch("auto", value = "auto"), .ch("irlba", value = "irlba", disk = FALSE),
                .ch("exact", value = "exact", disk = FALSE), .ch("random", value = "random")),
                if (factominer) list(.ch("factominer", value = "factominer"))), "auto"))),
            if (factominer) list(.advanced(.yes_no("rev", "reverse PCA", FALSE))),
            .seed_params(), list(.name_param("pca"))),
        umap = c(list(
            .pcs("dimensions_to_use", "PCs for UMAP"),
            .num("n_neighbors", "neighbors", "auto", c(2, 100), min = 2,
                integer = TRUE, auto = TRUE),
            .num("min_dist", "min dist", 0.05, c(0, 1), step = 0.01),
            .advanced(.num("spread", "spread", 1, c(0.1, 5), min = 0.01, step = 0.1)),
            .advanced(.num("n_epochs", "epochs", "auto", c(50, 2000), min = 1, integer = TRUE,
                auto = TRUE, log = TRUE)),
            .advanced(.param("init", "initialization", lapply(c("auto", "spectral", "pca",
                "spca", "agspectral", "laplacian", "random", "lvrandom"),
                function(m) .ch(if (m == "auto") NULL else m, value = m, label = m)), "auto")),
            .advanced(.num("n_components", "components", 2, c(2, 10), min = 2,
                integer = TRUE)),
            .advanced(.param("nn_engine", "neighbor search", lapply(c("giotto", "uwot", "fnn",
                "annoy", "hnsw", if (nndescent) "nndescent"),
                function(m) .ch(m, value = m)), "giotto")),
            .advanced(.param("method", "UMAP engine", list(.ch("umap2", value = "umap2"),
                .ch("umap", value = "umap")), "umap2")),
            .advanced(.yes_no("batch", "batch optimizer"))),
            .seed_params(), list(.name_param("umap"))),
        network = list(
            .param("type", "type", list(.ch("sNN", value = "sNN"),
                .ch("kNN", value = "kNN")), "sNN"),
            .pcs("dimensions_to_use", "PCs for network"),
            .num("k", "k", 30, c(2, 100), min = 2, integer = TRUE),
            utils::modifyList(.advanced(.param("engine", "engine", list(
                .ch("dbscan", "dbscan (exact)", value = "dbscan"),
                .ch("hnsw", "hnsw (approximate)", value = "hnsw")), "hnsw")),
                list(code_default = "dbscan")),
            .advanced(.num("minimum_shared", "minimum shared", 5, c(0, 30), min = 0,
                integer = TRUE)),
            .advanced(.num("top_shared", "top shared", 3, c(0, 30), min = 0, integer = TRUE)),
            .advanced(.num("ef", "search width (hnsw)", 200, c(10, 1000), min = 1,
                integer = TRUE, log = TRUE)),
            .advanced(.yes_no("keep_knn", "keep kNN")),
            .name_param("", "type.pca, e.g. sNN.pca")
        ),
        leiden = c(list(
            .num("resolution", "resolution", 1, c(0.01, 5), min = 0.001, log = TRUE),
            .advanced(.num("n_iterations", "iterations", 20, c(1, 200), min = 1,
                integer = TRUE)),
            .advanced(.param("objective_function", "objective function", list(
                .ch("modularity", value = "modularity"), .ch("CPM", value = "CPM")),
                "modularity")),
            .advanced(.num("beta", "randomness (beta)", 0.01, c(0.001, 1), min = 0,
                log = TRUE)),
            .advanced(.param("weights", "edge weights", list(
                .ch(NULL, "network weights", value = "auto"),
                .ch(NA, "none", value = "NA")), "auto"))),
            .seed_params(), list(.name_param("leiden_clus"))),
        markers = list(
            .values_param(c("scaled", "normalized")),
            .param("method", "method", list(.ch("scran", value = "scran"),
                .ch("gini", value = "gini")), "scran"),
            .num("top", "markers shown", 5, c(1, 20), min = 1, max = 50, integer = TRUE),
            .advanced(.text_param("subset_clusters", "clusters", placeholder = "all clusters")),
            .advanced(.num("min_feats", "min markers per cluster", 10, c(1, 50), min = 0,
                integer = TRUE)),
            .advanced(.num("pval", "max p-value", 0.01, c(1e-6, 1), min = 0, max = 1,
                log = TRUE)),
            .advanced(.num("logFC", "min log fold change", 0.5, c(0, 5), min = 0, step = 0.1)),
            .advanced(.num("min_expression", "min expression", 0.5, c(0, 5), min = 0,
                step = 0.1)),
            .advanced(.num("min_detection", "min detection", 0.5, c(0, 1), min = 0, max = 1,
                step = 0.05)),
            .advanced(.num("min_expression_gini", "min expression Gini", "auto", c(0, 1),
                min = -1, max = 1, step = 0.01, auto = TRUE)),
            .advanced(.num("min_detection_gini", "min detection Gini", "auto", c(0, 1),
                min = -1, max = 1, step = 0.01, auto = TRUE)),
            .advanced(.num("detection_threshold", "detection threshold", 0, c(0, 5), min = 0,
                step = 0.1)),
            .advanced(.num("min_length", "Gini padding length", 0, c(0, 50), min = 0,
                integer = TRUE)),
            .advanced(.num("rank_score", "max rank", "auto", c(1, 20), min = 1,
                integer = TRUE, auto = TRUE))
        ),
        auto_type = list(
            .values_param(c("scaled", "normalized")),
            .param("method", "method", list(.ch("PAGE", value = "PAGE"),
                .ch("hypergeometric", value = "hypergeometric")), "PAGE"),
            .num("min_overlap_genes", "min overlap genes (PAGE)", 5, c(0, 20),
                min = 0, integer = TRUE),
            .num("top_percentage", "top % expressed (hypergeometric)", 5, c(1, 50),
                min = 0.1, max = 100, step = 0.5),
            .advanced(.param("output_enrichment", "scores", list(
                .ch("original", value = "original"), .ch("zscore", value = "zscore")),
                "original")),
            .advanced(.yes_no("p_value", "p-values", FALSE)),
            .advanced(.yes_no("include_depletion", "include depletion", FALSE)),
            .advanced(.param("reverse_log_scale", "reverse log scale", list(
                .ch(NULL, "auto", value = "auto"), .ch(TRUE, "yes"), .ch(FALSE, "no")),
                "auto")),
            .advanced(.num("logbase", "log base", 2, c(1.5, 10), min = 1.0001, step = 0.5)),
            .name_param("", "the method, e.g. PAGE")
        ),
        labels = list(.name_param("cell_type"))
    )
}

# "argument = value" for Preprocessing step `s` (see .code_args())
.preprocess_args <- function(s, p, ids)
    .code_args(.preprocess_params()[[s]], p, ids, .analysis_show_preprocess()[[s]])

.analysis_entry_preprocess <- function() {
    par <- .preprocess_params()
    list(
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
            params = par$filter,
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
            params = par$normalize,
            run = function(g, p) Giotto::normalizeGiotto(g,
                norm_methods = p$norm_methods, library_size_norm = p$library_size_norm,
                scalefactor = p$scalefactor, log_norm = p$log_norm,
                logbase = p$logbase,
                scale_feats = p$scale, scale_cells = p$scale, scale_order = p$scale_order,
                theta = p$theta, verbose = FALSE),
            result = function(g, p, before) list(summary = paste0(
                "writes ", if (isTRUE(p$scale)) "normalized and scaled" else "normalized",
                " values")),
            code = function(p, up) paste0("g <- normalizeGiotto(g, ", paste(c(
                .preprocess_args("normalize", p, c("norm_methods", "library_size_norm",
                    "scalefactor", "log_norm", "logbase",
                    scale_feats = "scale", scale_cells = "scale", "scale_order", "theta"))),
                collapse = ", "), ")")
        ),

        hvf = list(
            label = "Highly variable features", input = "normalize",
            fun = "calculateHVF",
            params = par$hvf,
            run = function(g, p) Giotto::calculateHVF(g,
                expression_values = .lens_values(p), method = p$method,
                reverse_log_scale = p$reverse_log_scale, logbase = p$logbase,
                expression_threshold = p$expression_threshold,
                nr_expression_groups = p$nr_expression_groups,
                zscore_threshold = p$zscore_threshold,
                difference_in_cov = p$difference_in_cov,
                var_threshold = p$var_threshold, n_top_feats = p$n_top_feats,
                theta = p$theta, random_subset = p$random_subset,
                set_seed = p$set_seed, seed_number = p$seed_number, calc_gini = p$calc_gini,
                show_plot = FALSE, return_plot = FALSE, save_plot = FALSE),
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                n <- sum(fm$hvf == "yes")
                list(hvf = fm[intersect(names(fm), c("feat_ID", "mean_expr", "mean_expr_det",
                        "cov", "var", "hvf"))],
                    summary = sprintf("%d of %d features", n, nrow(fm)))
            },
            code = function(p, up) paste0("g <- calculateHVF(g, ", paste(c(
                paste0("expression_values = ", .code_value(.values_of(p, up))),
                .preprocess_args("hvf", p, c("method", "reverse_log_scale", "logbase",
                    "expression_threshold", "nr_expression_groups", "zscore_threshold",
                    "difference_in_cov", "var_threshold", "n_top_feats", "theta",
                    "random_subset", "set_seed", "seed_number", "calc_gini"))),
                collapse = ", "), ")")
        ),

        pca = list(
            label = "PCA", input = "hvf",
            fun = "runPCA",
            params = par$pca,
            run = function(g, p) Giotto::runPCA(g,
                expression_values = .lens_values(p), feats_to_use = p$feats_to_use,
                center = p$center, scale_unit = p$scale_unit, ncp = p$ncp,
                method = p$method, rev = isTRUE(p$rev),
                set_seed = p$set_seed, seed_number = p$seed_number,
                name = .lens_names(list(pca = p))$pca),
            result = function(g, p, before) {
                d <- GiottoClass::getDimReduction(g, reduction_method = "pca",
                    name = .lens_names(list(pca = p))$pca, output = "dimObj")
                ev <- d@misc$eigenvalues
                list(elbow = data.frame(PC = seq_along(ev), variance = ev / sum(ev)),
                    summary = sprintf("%d components", length(ev)))
            },
            code = function(p, up) {
                a <- c(.preprocess_args("pca", p, c("feats_to_use", "center", "scale_unit",
                    "ncp", "method", "rev", "set_seed", "seed_number")),
                    paste0("name = ", .code_value(.pre_names(list(pca = p))$pca)))
                if (is.null(p$feats_to_use)) a <- c("feats_to_use = NULL", a)
                paste0("g <- runPCA(g, expression_values = ",
                    .code_value(.values_of(p, up)), ", ", paste(a, collapse = ", "), ")")
            }
        ),

        umap = list(
            label = "UMAP", input = "pca",
            fun = "runUMAP",
            params = par$umap,
            run = function(g, p) Giotto::runUMAP(g,
                expression_values = .lens_values(p),
                dim_reduction_name = .lens_names(p$up)$pca,
                name = .lens_names(list(umap = p))$umap,
                dimensions_to_use = p$dimensions_to_use, n_neighbors = p$n_neighbors,
                n_components = p$n_components, n_epochs = p$n_epochs,
                min_dist = p$min_dist, spread = p$spread, init = p$init,
                method = p$method, batch = p$batch, nn_engine = p$nn_engine,
                set_seed = p$set_seed, seed_number = p$seed_number,
                n_threads = .lens_threads()),
            result = function(g, p, before) {
                nm <- .lens_names(list(umap = p))$umap
                m <- GiottoClass::getDimReduction(g, reduction_method = "umap",
                    name = nm, output = "matrix")
                meta <- data.frame(cell_ID = rownames(m), m[, 1L], m[, 2L])
                names(meta)[2:3] <- paste0(nm, c("_1", "_2"))
                list(meta = meta)
            },
            code = function(p, up) paste0("g <- runUMAP(g, expression_values = ",
                .code_value(.values_of(p, up)), ", dim_reduction_name = ",
                .code_value(.pre_names(up)$pca), ", ", paste(c(
                .preprocess_args("umap", p, c("dimensions_to_use", "n_neighbors",
                    "n_components", "n_epochs", "min_dist", "spread", "init", "method",
                    "batch", "nn_engine", "set_seed", "seed_number")),
                paste0("name = ", .code_value(.pre_names(list(umap = p))$umap))),
                collapse = ", "), ")")
        ),

        network = list(
            label = "Nearest network", input = "pca",
            fun = "createNearestNetwork",
            params = par$network,
            run = function(g, p) Giotto::createNearestNetwork(g, type = p$type,
                expression_values = .lens_values(p),
                dim_reduction_name = .lens_names(p$up)$pca,
                name = .lens_names(list(network = p))$network,
                dimensions_to_use = p$dimensions_to_use, k = p$k,
                minimum_shared = p$minimum_shared, top_shared = p$top_shared,
                engine = p$engine, ef = p$ef, keep_knn = p$keep_knn),
            result = function(g, p, before) list(),
            code = function(p, up) paste0("g <- createNearestNetwork(g, expression_values = ",
                .code_value(.values_of(p, up)), ", dim_reduction_name = ",
                .code_value(.pre_names(up)$pca), ", ", paste(c(
                .preprocess_args("network", p, c("type", "dimensions_to_use", "k",
                    "minimum_shared", "top_shared", "engine", "ef", "keep_knn")),
                paste0("name = ", .code_value(.pre_names(list(network = p))$network))),
                collapse = ", "), ")")
        ),

        leiden = list(
            label = "Leiden clusters", input = "network",
            fun = "doLeidenCluster",
            params = par$leiden,
            run = function(g, p) Giotto::doLeidenCluster(g, nn_network_to_use = p$up$network$type,
                network_name = .lens_names(p$up)$network,
                objective_function = p$objective_function, weights = p$weights,
                resolution = p$resolution, beta = p$beta, n_iterations = p$n_iterations,
                set_seed = p$set_seed, seed_number = p$seed_number,
                name = .lens_names(list(leiden = p))$leiden),
            result = function(g, p, before) {
                nm <- .lens_names(list(leiden = p))$leiden
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                cl <- as.character(cm[[nm]])
                lv <- as.character(sort(unique(as.integer(cl))))
                meta <- data.frame(cell_ID = as.character(cm$cell_ID))
                meta[[nm]] <- factor(cl, levels = lv)
                list(meta = meta, summary = sprintf("%d clusters", length(lv)))
            },
            code = function(p, up) paste0("g <- doLeidenCluster(g, nn_network_to_use = ",
                .code_value(up$network$type), ", network_name = ",
                .code_value(.pre_names(up)$network), ", ", paste(c(
                .preprocess_args("leiden", p, c("resolution", "n_iterations",
                    "objective_function", "beta", "weights", "set_seed", "seed_number")),
                paste0("name = ", .code_value(.pre_names(list(leiden = p))$leiden))),
                collapse = ", "), ")")
        ),

        markers = list(
            label = "Markers", input = "leiden",
            fun = "findMarkers_one_vs_all",
            params = par$markers,
            run = function(g, p) g,
            result = function(g, p, before) {
                sc <- trimws(strsplit(paste(p$subset_clusters, collapse = ","), ",",
                    fixed = TRUE)[[1L]])
                sc <- sc[!is.na(sc) & nzchar(sc)]
                m <- as.data.frame(Giotto::findMarkers_one_vs_all(g,
                    expression_values = .lens_values(p),
                    cluster_column = .lens_names(p$up)$leiden,
                    subset_clusters = if (length(sc)) sc, method = p$method,
                    pval = p$pval, logFC = p$logFC, min_feats = p$min_feats,
                    min_expression = p$min_expression, min_detection = p$min_detection,
                    min_expression_gini = if (is.null(p$min_expression_gini)) -Inf
                        else p$min_expression_gini,
                    min_detection_gini = if (is.null(p$min_detection_gini)) -Inf
                        else p$min_detection_gini,
                    detection_threshold = p$detection_threshold, min_length = p$min_length,
                    rank_score = if (is.null(p$rank_score)) Inf else p$rank_score,
                    verbose = FALSE))
                rank_col <- if (p$method == "gini") "comb_rank" else "Top"
                score_col <- if (p$method == "gini") "comb_score" else "logFC"
                m <- m[order(m$cluster, m[[rank_col]]), ]
                m <- do.call(rbind, lapply(split(m, m$cluster), utils::head, p$top))
                list(markers = data.frame(cluster = as.character(m$cluster),
                    feat = as.character(m$feats), score = m[[score_col]]))
            },
            code = function(p, up) {
                sc <- .text_list(p$subset_clusters)
                paste0("markers <- findMarkers_one_vs_all(g, expression_values = ",
                    .code_value(.values_of(p, up)), ", cluster_column = ",
                    .code_value(.pre_names(up)$leiden), ", ",
                    paste(c(if (length(sc)) paste0("subset_clusters = ", .code_value(sc)),
                        .preprocess_args("markers", p, c("method", "pval", "logFC",
                            "min_feats", "min_expression", "min_detection",
                            "min_expression_gini", "min_detection_gini",
                            "detection_threshold", "min_length", "rank_score"))),
                        collapse = ", "), ")")
            }
        ),

        auto_type = list(
            label = "Automatic types", input = "leiden",
            fun = "runPAGEEnrich",
            params = par$auto_type,
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
                rev_log <- if (is.null(p$reverse_log_scale))
                    isTRUE(p$up$normalize$log_norm) && !isTRUE(p$up$normalize$scale)
                    else p$reverse_log_scale
                if (p$method == "PAGE") {
                    Giotto::runPAGEEnrich(g, sign_matrix = sm, expression_values = .lens_values(p),
                        min_overlap_genes = p$min_overlap_genes, reverse_log_scale = rev_log,
                        logbase = p$logbase, output_enrichment = p$output_enrichment,
                        p_value = p$p_value, include_depletion = p$include_depletion,
                        name = .lens_names(list(auto_type = p))$auto_type, verbose = FALSE)
                } else {
                    Giotto::runHyperGeometricEnrich(g, sign_matrix = sm,
                        expression_values = .lens_values(p), top_percentage = p$top_percentage,
                        reverse_log_scale = rev_log, logbase = p$logbase,
                        output_enrichment = p$output_enrichment, p_value = p$p_value,
                        name = .lens_names(list(auto_type = p))$auto_type)
                }
            },
            result = function(g, p, before) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g,
                    name = .lens_names(list(auto_type = p))$auto_type, output = "data.table"))
                types <- setdiff(names(e), "cell_ID")
                m <- as.matrix(e[types])
                best <- types[max.col(m, ties.method = "first")]
                score <- apply(m, 1L, max)
                if (p$method != "PAGE") best[score <= 0] <- NA_character_
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                cl <- as.character(cm[[.lens_names(p$up)$leiden]][match(e$cell_ID, cm$cell_ID)])
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
            },
            code = function(p, up) {
                rev_log <- if (is.null(p$reverse_log_scale))
                    isTRUE(up$normalize$log_norm) && !isTRUE(up$normalize$scale)
                    else p$reverse_log_scale
                page <- p$method == "PAGE"
                a <- c(if (page) paste0("min_overlap_genes = ", .code_value(p$min_overlap_genes))
                    else paste0("top_percentage = ", .code_value(p$top_percentage)),
                    if (!isTRUE(rev_log)) "reverse_log_scale = FALSE",
                    .preprocess_args("auto_type", p, c("logbase", "output_enrichment",
                        "p_value", "include_depletion")))
                paste0("sign <- makeSignMatrixPAGE(sign_names = names(cell_markers), ",
                    "sign_list = cell_markers)\n",
                    "g <- ", if (page) "runPAGEEnrich" else "runHyperGeometricEnrich",
                    "(g, sign_matrix = sign, expression_values = ",
                    .code_value(.values_of(p, up)), ", ", paste(a, collapse = ", "),
                    ", name = ", .code_value(.pre_names(list(auto_type = p))$auto_type), ")")
            }
        ),

        labels = list(
            label = "Cell types", input = "leiden",
            fun = "annotateGiotto",
            params = par$labels,
            run = function(g, p) {
                clus <- .lens_names(p$up)$leiden
                cl <- as.character(sort(unique(as.integer(
                    GiottoClass::pDataDT(g)[[clus]]))))
                lab <- vapply(cl, function(k) {
                    v <- p$labels[[k]]
                    if (is.null(v) || !nzchar(v)) k else v
                }, "")
                Giotto::annotateGiotto(g, annotation_vector = stats::setNames(lab, cl),
                    cluster_column = clus, name = .lens_names(list(labels = p))$labels)
            },
            result = function(g, p, before) {
                nm <- .lens_names(list(labels = p))$labels
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                meta <- data.frame(cell_ID = as.character(cm$cell_ID))
                meta[[nm]] <- as.character(cm[[nm]])
                list(meta = meta)
            },
            code = function(p, up) {
                lab <- unlist(p$labels)
                if (!length(lab)) return("")
                paste0("g <- annotateGiotto(g, ", paste(c(paste0("annotation_vector = ",
                    .code_value(lab)), paste0("cluster_column = ", .code_value(.pre_names(up)$leiden)),
                    paste0("name = ", .code_value(.pre_names(list(labels = p))$labels))),
                    collapse = ", "), ")")
            }
        )
    ))
}

.analysis_help_preprocess <- function() list(
    filter = list(
        expression_threshold = paste0(
            "The raw count at which a gene counts as detected in a cell. For example, with 1 a ",
            "gene with at least one transcript in a cell is detected; with 2 a single transcript ",
            "is not. Higher values count fewer genes as detected, so more genes and cells fall ",
            "below the two cutoffs below."),
        feat_det_in_min_cells = paste0(
            "Minimum number of cells in which a gene must be detected to be kept. For example, ",
            "100 removes genes detected in fewer than 100 cells. Genes are filtered before cells."),
        min_det_feats_per_cell = paste0(
            "Minimum number of detected genes a cell must have to be kept. For example, 100 ",
            "removes cells with fewer than 100 detected genes. Higher values remove more small or ",
            "low-quality cells. The QC: cells plot shows this cutoff.")),
    normalize = list(
        norm_methods = paste0(
            "How raw counts are normalized. standard: each cell's counts are divided by its total ",
            "count and multiplied by the scale factor (then log transformed if log transform is ",
            "on). osmFISH, quantile and pearson_resid are offered for data in memory only."),
        library_size_norm = paste0(
            "Whether each cell's counts are divided by the cell's total count (its library size) ",
            "and multiplied by the scale factor. With no, cells with more transcripts keep higher ",
            "values for all genes, so cell size can drive PCA and clustering."),
        scalefactor = paste0(
            "The total count each cell is scaled to in standard normalization. For example, with ",
            "6000 a gene with 10 of a cell's 2000 counts gets 10 / 2000 × 6000 = 30 before the ",
            "log transform. It changes the size of the values, not how cells compare."),
        log_norm = paste0(
            "Whether the normalized values are log transformed (log2 of value + 1). Without the ",
            "log, a few highly expressed genes dominate PCA and clustering."),
        logbase = paste0(
            "The base of the log transform. For example, with 2 a value of 7 becomes ",
            "log2(7 + 1) = 3; with 10 it becomes log10(8) ≈ 0.9. A larger base makes all values ",
            "smaller by the same factor; it does not change how cells compare."),
        scale = paste0(
            "Whether each gene is z-scored (mean 0, standard deviation 1) after normalization, so ",
            "all genes have the same weight in PCA. Not available for GiottoDisk data; use PCA: ",
            "scale features instead."),
        scale_order = paste0(
            "The order of the two z-scores of z-score scale. features first: each gene is ",
            "z-scored over all cells, then each cell over all genes. cells first: the other way ",
            "round. The values differ slightly; features first keeps genes most comparable."),
        theta = paste0(
            "For pearson_resid. The overdispersion of the counts assumed when computing Pearson ",
            "residuals. For example, 100 assumes counts close to Poisson; lower values (for ",
            "example 10) assume more spread, which shrinks the residuals of highly expressed ",
            "genes.")),
    hvf = list(
        expression_values = paste0(
            "The expression values the step reads, from the object or from the Normalize step. ",
            "Empty: normalized."),
        method = paste0(
            "How highly variable genes are selected. A gene's variability is measured by its ",
            "coefficient of variation (standard deviation / mean). cov_groups: genes are binned ",
            "into groups by mean expression and compared within their group. cov_loess: each ",
            "gene is compared with the variation expected for its mean expression (a loess ",
            "curve). var_p_resid: genes are ranked by the variance of their Pearson residuals."),
        zscore_threshold = paste0(
            "For cov_groups. Within each group of genes with similar mean expression, a gene's ",
            "coefficient of variation is turned into a z-score; genes with a z-score above this ",
            "are highly variable. For example, 1.5 selects genes 1.5 standard deviations more ",
            "variable than their group. Lower values select more genes."),
        difference_in_cov = paste0(
            "For cov_loess. A curve is fitted through the coefficient of variation of all genes ",
            "against their mean expression; genes whose coefficient of variation is above the ",
            "curve by more than this are highly variable. For example, 0.1 selects genes at least ",
            "0.1 above the curve. Lower values select more genes."),
        var_threshold = paste0(
            "For var_p_resid. A Pearson residual measures how far a gene's count in a cell is ",
            "from the count expected from the gene's average and the cell's total count. Genes ",
            "whose residuals vary more than this across cells are highly variable. Lower values ",
            "select more genes."),
        n_top_feats = paste0(
            "The largest number of highly variable genes kept: when more genes pass the cutoff, ",
            "the most variable ones are kept. For example, 2000 keeps at most 2000 genes. Lower ",
            "values keep fewer genes."),
        expression_threshold = paste0(
            "For cov_groups and cov_loess. The normalized value above which a gene counts as ",
            "detected in a cell when its mean over detected cells is computed. For example, with ",
            "0 any value above 0 counts. Higher values ignore weak signal."),
        nr_expression_groups = paste0(
            "For cov_groups. The number of groups genes are split into by mean expression; each ",
            "gene's variation is compared within its group. For example, 20 makes groups of 5% ",
            "of the genes each. Fewer groups compare genes over a wider range of expression."),
        theta = paste0(
            "For var_p_resid. The overdispersion of the counts assumed when computing Pearson ",
            "residuals. For example, 100 assumes counts close to Poisson; lower values assume ",
            "more spread, which lowers the residual variance of highly expressed genes."),
        reverse_log_scale = paste0(
            "Whether the log transform of the normalized values is undone (base^value − 1) ",
            "before variation is measured. With yes, highly expressed genes vary more on the ",
            "count scale. Not available for GiottoDisk data."),
        logbase = paste0(
            "The base of the log transform that reverse log scale undoes. For example, with 2 a ",
            "value of 3 becomes 2^3 − 1 = 7. It must match the log base of Normalize."),
        random_subset = paste0(
            "Number of cells, picked at random, on which variation is measured. For example, ",
            "5000 uses 5000 random cells, which is faster on large sections. Must be at most ",
            "the number of cells. Empty: all cells."),
        calc_gini = paste0(
            "Whether the Gini index of each gene (how unevenly it is expressed across cells) is ",
            "also computed and added to the gene metadata. It takes extra time on large data."),
        set_seed = paste0(.seed_help("the random subset of cells is picked")$set_seed,
            " Used only with a random subset of cells."),
        seed_number = paste0(.seed_help("the random subset of cells is picked")$seed_number,
            " Used only with a random subset of cells.")),
    pca = list(
        name = paste0(
            "The name the PCA is stored under in the giotto object. Empty: pca."),
        expression_values = paste0(
            "The expression values PCA reads, from the object or from the Normalize step. ",
            "Empty: scaled when Normalize z-score scales, else normalized."),
        feats_to_use = paste0(
            "Genes used for PCA: the highly variable genes, or all genes. For small targeted ",
            "panels (a few hundred genes), all genes is often used."),
        ncp = paste0(
            "Number of principal components computed. Each component captures part of the ",
            "variation between cells; the PCA elbow plot shows how much each one adds."),
        scale_unit = paste0(
            "Whether each gene is scaled to the same variance before PCA. Without it, genes with ",
            "large values have more influence on the components."),
        center = paste0(
            "Whether each gene's mean is subtracted before PCA. With no, the first component ",
            "mostly follows the average expression level instead of differences between cells."),
        method = paste0(
            "How the components are computed. auto: picked by data size. irlba: fast, ",
            "approximate, computes only the components asked for. exact: full decomposition, ",
            "slow on large data. random: randomized, fast and approximate. GiottoDisk data ",
            "offers auto and random."),
        rev = paste0(
            "For factominer. Whether PCA is run on the transposed data (genes as observations)."),
        set_seed = .seed_help("PCA")$set_seed,
        seed_number = .seed_help("PCA")$seed_number),
    umap = list(
        name = paste0(
            "The name the UMAP is stored under in the giotto object. Empty: umap."),
        dimensions_to_use = paste0(
            "Principal components used to compute the UMAP, for example 1 to 10. Components after ",
            "the bend in the PCA elbow plot mostly add noise."),
        n_neighbors = paste0(
            "Number of neighboring cells UMAP considers for each cell, counting the cell itself. ",
            "Higher values (for example 50) show more of the overall structure; lower values ",
            "(for example 10) more local detail. Empty: 31, or the size of a stored kNN network ",
            "plus one."),
        min_dist = paste0(
            "Minimum distance between cells in the UMAP plot. Lower values (for example 0.01) ",
            "pack similar cells into tight groups; higher values (for example 0.5) spread them ",
            "out."),
        spread = paste0(
            "Overall scale of the UMAP plot; together with min dist it sets how clumped the cells ",
            "look. For example, 2 spreads the groups of cells further apart than 1."),
        n_epochs = paste0(
            "Number of optimization rounds of the layout. More epochs (for example 1000) give a ",
            "more settled layout and take longer. Empty: 500 below 10,000 cells, 200 above."),
        init = paste0(
            "The starting layout that UMAP refines. spectral: from the neighbor graph. pca: the ",
            "first principal components. spca: pca scaled to a small spread. agspectral and ",
            "laplacian: variants of spectral. random and lvrandom: random positions. auto: pca ",
            "above 50,000 cells, spectral otherwise."),
        n_components = paste0(
            "Number of UMAP dimensions computed. The viewer shows dimensions 1 and 2."),
        nn_engine = paste0(
            "How each cell's nearest neighbors are found for UMAP. giotto: from a stored kNN ",
            "network or an approximate search, the same each run. uwot: uwot picks a search, ",
            "not the same each run. fnn: exact. annoy: approximate, the same each run with a ",
            "seed. hnsw: approximate and fast, not the same each run."),
        method = paste0(
            "The uwot function that computes the layout: umap2 or umap. Both take the same ",
            "settings."),
        batch = paste0(
            "Whether the layout is optimized in batches over several threads. Batches give the ",
            "same result with any number of threads."),
        set_seed = .seed_help("UMAP")$set_seed,
        seed_number = .seed_help("UMAP")$seed_number),
    network = list(
        name = paste0(
            "The name the network is stored under in the giotto object. Empty: the type and .pca, for example sNN.pca."),
        type = paste0(
            "The network of cells with similar expression that Leiden clusters. kNN: each cell is ",
            "connected to its k most similar cells. sNN: connections are kept between cells that ",
            "share many of those neighbors, weighted by how many they share."),
        dimensions_to_use = paste0(
            "Principal components used to measure how similar two cells are, for example 1 to 10."),
        k = paste0(
            "Number of most similar cells each cell is connected to. For example, 30 connects ",
            "each cell to the 30 cells with the most similar expression. Higher values give ",
            "fewer, larger clusters; lower values more, smaller clusters."),
        engine = paste0(
            "How the most similar cells are found. dbscan: exact. hnsw: approximate and faster ",
            "for large data."),
        minimum_shared = paste0(
            "For sNN. Minimum number of shared neighbors two cells need to stay connected. For ",
            "example, with 5 two cells sharing 4 of their k neighbors are not connected (unless ",
            "top shared keeps them). Higher values keep fewer connections."),
        top_shared = paste0(
            "For sNN. Number of connections kept for each cell, those with the most shared ",
            "neighbors, even when they share fewer than minimum shared. For example, 3 keeps at ",
            "least 3 connections per cell, so no cell is left alone."),
        ef = paste0(
            "For hnsw. How widely the approximate search looks. For example, 200 finds almost ",
            "the same neighbors as the exact search; higher values come closer to it and take ",
            "longer."),
        keep_knn = paste0(
            "For sNN. Whether the kNN network the sNN is built from is also stored in the object, ",
            "so later steps can reuse it.")),
    leiden = list(
        name = paste0(
            "The name the cluster column is stored under in the giotto object. Empty: leiden_clus."),
        resolution = paste0(
            "How finely the network is split into clusters. Higher values (for example 2) give ",
            "more, smaller clusters; lower values (for example 0.3) fewer, larger clusters."),
        n_iterations = paste0(
            "Number of iterations of the Leiden algorithm. More iterations can refine the ",
            "clusters and take longer."),
        objective_function = paste0(
            "What a good split of the network is. modularity: more connections within clusters ",
            "than expected by chance. CPM: connections within clusters compared with the ",
            "resolution itself; CPM needs much lower resolutions (for example 0.01), as 1 puts ",
            "most cells in their own cluster."),
        beta = paste0(
            "Randomness when cells are moved between clusters during refinement. For example, ",
            "0.01 makes moves close to the best ones; higher values allow more random moves."),
        weights = paste0(
            "Whether connection weights are used. network weights: connections between cells ",
            "that share more neighbors count more. none: all connections count the same."),
        set_seed = .seed_help("clustering")$set_seed,
        seed_number = .seed_help("clustering")$seed_number),
    markers = list(
        expression_values = paste0(
            "The expression values the marker test reads, from the object or from the Normalize step. ",
            "Empty: scaled when Normalize z-score scales, else normalized."),
        method = paste0(
            "How marker genes are found for each cluster. scran: a statistical test of each ",
            "cluster against all other cells. gini: genes with high expression in one cluster and ",
            "low expression in the others."),
        top = paste0(
            "Number of marker genes listed for each cluster next to its label."),
        subset_clusters = paste0(
            "Clusters compared, as comma-separated cluster numbers, for example 1, 3, 4. Only ",
            "cells of these clusters are used, and only these clusters get markers. Empty: all ",
            "clusters."),
        min_feats = paste0(
            "Minimum number of genes kept for each cluster, even when they do not pass the ",
            "filters below. For example, 10 keeps the 10 best-ranked genes of each cluster."),
        pval = paste0(
            "For scran. Genes with a p-value above this are dropped (beyond min markers per ",
            "cluster). For example, 0.01 keeps genes with p ≤ 0.01. Lower values keep fewer ",
            "genes."),
        logFC = paste0(
            "For scran. Genes with a log fold change below this are dropped (beyond min markers ",
            "per cluster). For example, 0.5 keeps genes at least 2^0.5 ≈ 1.4 times higher in the ",
            "cluster. Higher values keep fewer genes."),
        min_expression = paste0(
            "For gini. Minimum mean expression of a gene in the cluster. For example, 0.5 drops ",
            "genes with a cluster mean below 0.5 (normalized values)."),
        min_detection = paste0(
            "For gini. Minimum fraction of the cluster's cells that express the gene. For ",
            "example, 0.5 drops genes expressed in fewer than half of the cluster's cells."),
        min_expression_gini = paste0(
            "For gini. Minimum Gini coefficient of the gene's mean expression across clusters ",
            "(0: even, 1: all in one cluster). For example, 0.3 drops genes spread evenly over ",
            "clusters. Empty: no cutoff."),
        min_detection_gini = paste0(
            "For gini. Minimum Gini coefficient of the gene's detection across clusters. For ",
            "example, 0.3 drops genes detected in a similar fraction of cells in all clusters. ",
            "Empty: no cutoff."),
        detection_threshold = paste0(
            "For gini. The expression value above which a cell counts as expressing a gene. For ",
            "example, 0 counts any value above 0; 1 ignores weak signal."),
        min_length = paste0(
            "For gini. The per-cluster values are padded to this many clusters before the Gini ",
            "coefficient is taken, so scores compare across runs with different numbers of ",
            "clusters. For example, 20 pads to 20 clusters. 0: no padding."),
        rank_score = paste0(
            "For gini. Keeps a gene when the cluster ranks within this many of the highest ",
            "clusters for both expression and detection. For example, 1 keeps a gene only for ",
            "the cluster where it is highest. Empty: no cutoff.")),
    auto_type = list(
        name = paste0(
            "The name the enrichment scores is stored under in the giotto object. Empty: the method, PAGE or hypergeometric."),
        expression_values = paste0(
            "The expression values the scoring reads, from the object or from the Normalize step. ",
            "Empty: scaled when Normalize z-score scales, else normalized."),
        method = paste0(
            "How each cell is scored for each cell type of the marker list. PAGE: compares the ",
            "expression of the type's marker genes in the cell with their average over all cells. ",
            "hypergeometric: tests whether the type's marker genes are among the cell's most ",
            "expressed genes."),
        min_overlap_genes = paste0(
            "For PAGE. Cell types with this many or fewer of their marker genes in the gene panel ",
            "are not scored. For example, with 5 a type needs at least 6 marker genes in the ",
            "panel."),
        top_percentage = paste0(
            "For hypergeometric. The percentage of each cell's genes, ranked by expression, that ",
            "count as expressed. For example, 5 counts the top 5% of genes in each cell. Higher ",
            "values make the test less strict."),
        output_enrichment = paste0(
            "The scores stored. original: the scores as computed. zscore: each cell type's ",
            "scores standardized over all cells (mean 0, standard deviation 1), so types with ",
            "many and few marker genes compare."),
        p_value = paste0(
            "Whether p-values are also computed for each cell and type, stored next to the ",
            "scores with Benjamini-Hochberg adjusted p-values."),
        include_depletion = paste0(
            "For PAGE with p-values. Whether lower than expected marker expression also counts ",
            "as significant (a two-sided test on the z-score)."),
        reverse_log_scale = paste0(
            "Whether the log transform of the values is undone before scoring. auto: yes when ",
            "Normalize log transforms without z-score scaling, no otherwise."),
        logbase = paste0(
            "The base of the log transform that reverse log scale undoes. For example, with 2 a ",
            "value of 3 becomes 2^3 − 1 = 7. It must match the log base of Normalize.")),
    labels = list(
        name = paste0(
            "The name of the cell metadata column that holds the cell types. Empty: cell_type."))
)

.analysis_show_preprocess <- function() list(
    normalize = list(
        library_size_norm = list(norm_methods = "standard"),
        scalefactor = list(norm_methods = "standard", library_size_norm = "TRUE"),
        logbase = list(norm_methods = "standard", log_norm = "TRUE"),
        scale_order = list(norm_methods = "standard", scale = "TRUE"),
        theta = list(norm_methods = "pearson_resid")),
    hvf = list(
        zscore_threshold = list(method = "cov_groups"),
        difference_in_cov = list(method = "cov_loess"),
        var_threshold = list(method = "var_p_resid"),
        expression_threshold = list(method = c("cov_groups", "cov_loess")),
        nr_expression_groups = list(method = "cov_groups"),
        theta = list(method = "var_p_resid"),
        logbase = list(reverse_log_scale = "TRUE"),
        seed_number = list(set_seed = "TRUE")),
    pca = list(
        rev = list(method = "factominer"),
        seed_number = list(set_seed = "TRUE")),
    umap = list(seed_number = list(set_seed = "TRUE")),
    network = list(
        minimum_shared = list(type = "sNN"),
        top_shared = list(type = "sNN"),
        keep_knn = list(type = "sNN"),
        ef = list(engine = "hnsw")),
    leiden = list(seed_number = list(set_seed = "TRUE")),
    markers = list(
        pval = list(method = "scran"),
        logFC = list(method = "scran"),
        min_expression = list(method = "gini"),
        min_detection = list(method = "gini"),
        min_expression_gini = list(method = "gini"),
        min_detection_gini = list(method = "gini"),
        detection_threshold = list(method = "gini"),
        min_length = list(method = "gini"),
        rank_score = list(method = "gini")),
    auto_type = list(
        min_overlap_genes = list(method = "PAGE"),
        top_percentage = list(method = "hypergeometric"),
        include_depletion = list(method = "PAGE", p_value = "TRUE"),
        logbase = list(reverse_log_scale = c("auto", "TRUE")))
)
