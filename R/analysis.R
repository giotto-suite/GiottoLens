# ── Analysis (adr/0021, adr/0022) ────────────────────────────────────────────

# The folder of saved spatial networks: option GiottoLens.network_dir, else
# GiottoLens's user cache
.default_network_dir <- function() {
    getOption("GiottoLens.network_dir",
        file.path(tools::R_user_dir("GiottoLens", "cache"), "networks"))
}

# ── Worker side (runs in the jobs' daemon, adr/0025) ────────────────────────
#
# Each function here is a job's `fun(g, ...)`: `g` is the object the daemon
# holds for the snapshot shown, never modified. The analysis keeps its state
# in the daemon's global `.lens_a`: the base object (`g` with the analysis's
# spatial unit and feature type active), the step cache by key, and the
# spatial networks steps made.

# Set up `.lens_a` for root key `root` (the snapshot shown), unless it is set
# up for it already. Returns what the main side needs to know of the object.
.aw_init <- function(g, root, spat_unit, feat_type, threads, network_dir, cap_mb,
                     helpers = list()) {
    options(giotto.check_core = FALSE, giotto.cores = threads,
        tilework.warn_sequential = FALSE, giotto.use_conda = FALSE)
    requireNamespace("Giotto", quietly = TRUE)
    data.table::setDTthreads(threads)
    assign(".lens_threads", function() threads, envir = globalenv())
    for (n in names(helpers)) assign(n, helpers[[n]], envir = globalenv())
    w <- get0(".lens_a", envir = globalenv(), inherits = FALSE)
    if (is.null(w) || !identical(w$root, root)) {
        GiottoClass::instructions(g, "active_spat_unit", initialize = FALSE) <- spat_unit
        GiottoClass::instructions(g, "active_feat_type", initialize = FALSE) <- feat_type
        w <- new.env()
        w$root  <- root
        w$base  <- g
        w$cache <- list()
        w$sizes <- list()
        w$networks <- list()
        w$named <- list()
        w$kept <- list()
        w$key <- NULL
        assign(".lens_a", w, envir = globalenv())
    }
    w$network_dir <- network_dir
    w$cap <- cap_mb * 2^20
    w$note <- character()
    if (requireNamespace("progressr", quietly = TRUE)) {
        report <- function(config, state, progression, ...)
            .lens_progress(state$step, config$max_steps)
        options(progressr.enable = TRUE)
        progressr::handlers(progressr::make_progression_handler("lens",
            reporter = list(initiate = report, update = report),
            intrusiveness = 0, interval = 0, enable = TRUE))
    }
    raw <- GiottoClass::getExpression(w$base, values = "raw", output = "exprObj")[]
    list(disk = inherits(raw, "parquetExprStore"), n_cells = ncol(raw), n_feats = nrow(raw))
}

# The object a key stands for: the base for the root, else a cached step
.aw_object <- function(key) {
    w <- get(".lens_a", envir = globalenv())
    if (identical(key, w$root)) w$base else w$cache[[key]]
}

# One step: its result object is cached under `key`. The cache keeps the
# `current` keys and the most `recent` others, and drops the oldest of those
# while it holds more than its cap (sizes as object.size() gives them,
# counting shared parts more than once).
.aw_step <- function(g, run, result, key, parent, p, current, recent) {
    w <- get0(".lens_a", envir = globalenv(), inherits = FALSE)
    if (is.null(w)) stop("lens_missing_input")
    before <- if (is.null(parent)) w$base else w$cache[[parent]]
    if (is.null(before)) stop("lens_missing_input")
    t0 <- proc.time()[["elapsed"]]
    w$note <- character()
    w$key <- key
    out <- w$cache[[key]]
    if (is.null(out)) {
        out <- run(before, p)
        w$sizes[[key]] <- as.numeric(utils::object.size(out))
    }
    w$cache[[key]] <- out
    keep <- unique(c(current, recent))
    w$cache <- w$cache[intersect(names(w$cache), keep)]
    old <- setdiff(intersect(recent, names(w$cache)), current)
    while (length(old) && sum(unlist(w$sizes[names(w$cache)])) > w$cap) {
        w$cache[[old[[1L]]]] <- NULL
        old <- old[-1L]
    }
    w$sizes <- w$sizes[names(w$cache)]
    w$kept <- w$kept[intersect(names(w$kept), names(w$cache))]
    res <- result(out, p, before)
    if (length(w$note) && !is.null(res$summary))
        res$summary <- paste0(res$summary, " (", paste(w$note, collapse = "; "), ")")
    list(result = res, secs = proc.time()[["elapsed"]] - t0)
}

# ── Worker helpers (assigned in the worker's global environment) ────────────

# Keeps `x` with the running step's result, for its `result()`
.aw_keep <- function(x) {
    w <- get(".lens_a", envir = globalenv())
    w$kept[[w$key]] <- x
    invisible()
}

# What the running step's `run()` kept, or NULL
.aw_kept <- function() {
    w <- get(".lens_a", envir = globalenv())
    w$kept[[w$key]]
}

# Adds a short text to the summary of the running step
.aw_note <- function(text) {
    w <- get(".lens_a", envir = globalenv())
    w$note <- c(w$note, text)
    invisible()
}

# Counts the calls of function `fun` of namespace `ns` while `expr` runs, as
# progress out of `total`; `expr` runs without counting when `fun` is absent
.aw_count_calls <- function(expr, ns, fun, total, what) {
    env <- asNamespace(ns)
    if (!exists(fun, envir = env, inherits = FALSE) || !total) return(expr)
    n <- 0
    tick <- function() {
        n <<- n + 1
        .lens_progress(n, total, what)
    }
    assign(".lens_tick", tick, envir = globalenv())
    ok <- tryCatch({
        suppressMessages(trace(fun, tracer = quote(.lens_tick()), where = env, print = FALSE))
        TRUE
    }, error = function(e) FALSE)
    if (ok) on.exit(suppressMessages(untrace(fun, where = env)), add = TRUE)
    .lens_progress(0, total, what)
    expr
}

# Mean silhouette width of clustering `cl` (integers 1..k) on the distance
# matrix `d`; a cell alone in its cluster counts 0
.aw_silhouette <- function(d, cl) {
    n <- length(cl)
    k <- max(cl)
    m <- matrix(0, n, k)
    m[cbind(seq_len(n), cl)] <- 1
    s <- d %*% m
    size <- colSums(m)
    a <- s[cbind(seq_len(n), cl)] / pmax(size[cl] - 1, 1)
    other <- sweep(s, 2L, pmax(size, 1), "/")
    other[, size == 0] <- Inf
    other[cbind(seq_len(n), cl)] <- Inf
    b <- apply(other, 1L, min)
    w <- (b - a) / pmax(a, b)
    w[size[cl] == 1 | !is.finite(w)] <- 0
    mean(w)
}

# The spatial network `name` of `g`. With `params`, a new network: kept in
# the worker and written to `network_dir` under a hash of the cells, their
# coordinates and `params`; created with `create(g)` when neither has it.
# Without, a network of `g` or one a step stored under `name` before.
.aw_network <- function(g, params, create, name) {
    w <- get(".lens_a", envir = globalenv())
    su <- GiottoClass::activeSpatUnit(g)
    if (is.null(params)) {
        if (name %in% GiottoClass::list_spatial_networks_names(g, spat_unit = su)) return(g)
        net <- w$named[[name]]
        if (is.null(net)) stop("no spatial network '", name, "'; run the analysis that ",
            "makes it first", call. = FALSE)
        .lens_note(paste0("network '", name, "' from another analysis"))
        return(GiottoClass::setGiotto(g, net, verbose = FALSE))
    }
    xy <- as.data.frame(GiottoClass::getSpatialLocations(g, output = "data.table"))
    xy <- xy[order(xy$cell_ID), c("cell_ID", "sdimx", "sdimy")]
    tmp <- tempfile(fileext = ".rds")
    saveRDS(list(xy, params), tmp, compress = FALSE)
    key <- unname(tools::md5sum(tmp))
    unlink(tmp)
    net <- w$networks[[key]]
    file <- if (!is.null(w$network_dir)) file.path(w$network_dir, paste0(key, ".rds"))
    from_disk <- is.null(net)
    if (from_disk && !is.null(file) && file.exists(file))
        net <- tryCatch({
            x <- readRDS(file)
            if (inherits(x@network, "parquetEdgeStore") && !dir.exists(x@network@path))
                NULL
            else x
        }, error = function(e) NULL)
    if (!is.null(net)) {
        net@name <- name
        out <- tryCatch(GiottoClass::setGiotto(g, net, verbose = FALSE),
            error = function(e) NULL)
        if (!is.null(out)) {
            .lens_note(if (from_disk) "saved network read from disk"
                else "saved network reused")
            w$networks[[key]] <- net
            w$named[[name]] <- net
            return(out)
        }
    }
    g <- create(g)
    net <- GiottoClass::getSpatialNetwork(g, name = name, output = "spatialNetworkObj")
    w$networks[[key]] <- net
    w$named[[name]] <- net
    if (!is.null(file)) tryCatch({
        dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
        saved <- net
        if (inherits(net@network, "parquetEdgeStore")) {
            edges <- data.table::as.data.table(GiottoClass::getSpatialNetwork(g,
                name = name, output = "networkDT"))
            store <- GiottoDisk::parquetEdgeStore(path = file.path(w$network_dir, key),
                type = "spatial")
            saved@network <- GiottoDisk::storeWrite(store, edges, type = "spatial",
                directed = isTRUE(net@network@directed),
                node_universe = as.character(GiottoClass::spatIDs(g)))
        }
        saveRDS(saved, file)
    }, error = function(e) {
        unlink(c(file, file.path(w$network_dir, key)), recursive = TRUE)
        .lens_note(paste("network not saved:", conditionMessage(e)))
    })
    g
}

# Helpers sent to the worker, by the name steps call them with
.aw_helpers <- function() lapply(list(
    .aw_object = .aw_object, .lens_note = .aw_note,
    .lens_keep = .aw_keep, .lens_kept = .aw_kept,
    .lens_count_calls = .aw_count_calls, .lens_silhouette = .aw_silhouette,
    .lens_network = .aw_network, .lens_values = .values_of, .lens_names = .pre_names,
    .lens_net = .network_of),
    .job_fun)

# Score of a gene set per cell in the result of step `key`: the mean of the
# genes' values, after z-scoring each gene for `stat = "zmean"`
.aw_gene_set <- function(g, key, genes, values, stat) {
    g <- .aw_object(key)
    if (is.null(g)) stop("the step's result is no longer held; run it again")
    genes <- intersect(genes, GiottoClass::featIDs(g))
    if (!length(genes)) stop("none of the genes is a feature of the object")
    d <- as.data.frame(suppressMessages(GiottoClass::spatValues(g, feats = genes,
        expression_values = values)))
    m <- as.matrix(d[genes])
    if (identical(stat, "zmean")) {
        s <- apply(m, 2L, stats::sd)
        m <- sweep(sweep(m, 2L, colMeans(m)), 2L, ifelse(s > 0, s, 1), "/")
    }
    list(cell_ID = as.character(d$cell_ID), value = rowMeans(m), genes = genes)
}

.aw_gobject <- function(g, key, umap_key, umap_name = "umap") {
    w <- get(".lens_a", envir = globalenv())
    g <- w$cache[[key]]
    if (is.null(g)) stop("the last step has no result yet")
    u <- if (!is.null(umap_key)) w$cache[[umap_key]]
    if (!is.null(u)) {
        d <- GiottoClass::getDimReduction(u, reduction_method = "umap", name = umap_name,
            output = "dimObj")
        keep <- intersect(GiottoClass::spatIDs(g), rownames(d[]))
        d[] <- d[][keep, , drop = FALSE]
        g <- GiottoClass::setGiotto(g, d, verbose = FALSE)
    }
    g
}

# One feature's `values` per cell from the object of key `key`, else the base
# object when that has no such values: an item the viewer reads for an
# analysis (adr/0021). Cells the step left out are absent.
.aw_item <- function(g, key, feat, values) {
    w <- get0(".lens_a", envir = globalenv(), inherits = FALSE)
    obj <- if (!is.null(w)) .aw_object(key)
    if (is.null(obj)) stop("the analysis step this gene is read from is no longer held; run it again")
    if (!values %in% as.data.frame(GiottoClass::list_expression(obj))$name) obj <- w$base
    if (!feat %in% GiottoClass::featIDs(obj)) stop("'", feat, "' is not a feature of the object")
    d <- as.data.frame(suppressMessages(GiottoClass::spatValues(obj, feats = feat,
        expression_values = values)))
    data.frame(cell_ID = as.character(d$cell_ID), item = as.numeric(d[[feat]]))
}

# ── LensAnalysis ─────────────────────────────────────────────────────────────

# The analysis's worker: the viewer's jobs (adr/0025), one call at a time,
# read by LensAnalysis's poll loop. `host` is the viewer's: start_job(),
# cancel() and a running job's progress file. A call's `fun(g, ...)` runs over
# the object the daemon holds.
.AnalysisWorker <- R6::R6Class(".AnalysisWorker",
    public = list(
        initialize = function(host) private$host <- host,
        call = function(fun, args, label = "analysis") {
            private$out <- NULL
            private$id <- private$host$start_job(label, fun, args, progress = TRUE,
                on_end = function(r) private$out <- .worker_out(r))
            invisible(self)
        },
        poll_process = function(timeout = 0) if (is.null(private$out)) "timeout" else "ready",
        read = function() {
            out <- private$out
            private$out <- NULL
            private$id <- NULL
            out
        },
        interrupt = function() {
            if (!is.null(private$id)) private$host$cancel(private$id, "cancelled by the analysis")
            invisible()
        },
        progress_file = function()
            if (is.null(private$id)) NA_character_ else private$host$progress_file(private$id),
        # A call waited for, beside the poll loop's: its value or an error
        run = function(fun, args, label = "analysis") {
            out <- NULL
            private$host$start_job(label, fun, args, on_end = function(r) out <<- .worker_out(r))
            while (is.null(out)) later::run_now(0.05)
            if (!is.null(out$error)) stop("[LensAnalysis] ", conditionMessage(out$error), call. = FALSE)
            out$result
        }
    ),
    private = list(host = NULL, id = NULL, out = NULL)
)

# A job's end as the poll loop reads it: list(result =) or list(error =)
.worker_out <- function(r) {
    if (identical(r$state, "done")) list(result = r$result)
    else list(error = simpleError(r$message %||% r$state))
}

# A short hash of a step key, for item keys
.key_hash <- function(key) {
    f <- tempfile()
    on.exit(unlink(f))
    writeLines(key, f, useBytes = TRUE)
    substr(unname(tools::md5sum(f)), 1L, 16L)
}

#' A viewer's analysis
#'
#' The analysis behind the viewer's Analysis panel ([LensViewer] `$analysis()`).
#' Its Preprocessing tab runs the first steps of a Giotto analysis on the
#' object shown: QC filter ([Giotto::filterGiotto()]), normalization,
#' highly variable features, PCA, UMAP, nearest network, Leiden clustering,
#' markers ([Giotto::findMarkers_one_vs_all()]) and cell-type labels
#' ([Giotto::annotateGiotto()]). Each step has a menu or number box per
#' parameter. When Leiden reruns, each new cluster takes the label of the old
#' cluster holding more than half of its cells; labels typed for a clustering
#' come back when its parameters do. With `cell_markers`, the Automatic types
#' step scores each cell for each cell type ([Giotto::runPAGEEnrich()] or
#' [Giotto::runHyperGeometricEnrich()]) and fills each unlabeled cluster with
#' its best-scoring type, marked as a suggestion. Changing a
#' parameter reruns that step and the steps that depend on it; the others keep
#' their results. QC values, clusters, cell types and UMAP coordinates are
#' pushed as cell metadata; QC histograms, the HVF plot and the PCA elbow plot
#' are docked as panels.
#'
#' Further analyses are added from the Add analysis dialog, which shows each
#' analysis's description, inputs, outputs and steps, or with `analyses` and
#' [LensAnalysis] `$add()`; a menu switches between the included analyses.
#' For example, Spatial interactions links each cell to its neighbors
#' ([Giotto::createSpatialNetwork()], kNN with k = 20 by default) and tests
#' which pairs of cell types are neighbors more or less often than in random
#' relabelings ([Giotto::cellProximityEnrichment()]). Cell types come from a
#' categorical cell metadata column of `x` or of the analyses, and
#' expression from the Preprocessing tab or `x`. A values menu picks the
#' expression values each analysis reads: those of `x` for `spat_unit` and
#' `feat_type`, and those of the Normalize step. Each spatial network step
#' makes a new network, stored under a name, or uses a spatial network of `x`
#' or of another analysis by name. The PCA, UMAP, nearest network, Leiden,
#' enrichment, cell type and niche steps store their results under names set
#' in the viewer; empty names take Giotto's defaults. The steps of added analyses
#' run only when asked: the Run button of a step runs it and the stale steps
#' above it, Run all runs every stale step of the analysis, and `$run()` does
#' the same from R. A change marks the step and those below it stale and drops
#' their pending runs. Each finished run of an analysis is kept for the session
#' and listed under History, which brings back its parameters and results.
#' Clicking a gene in a result table colors the cells by its expression.
#'
#' The steps run as jobs in the viewer's background R process, over the
#' object it holds for the snapshot shown (adr/0025), so the viewer stays
#' responsive; a change made while a step runs cancels that step when its
#' result would be stale. Each step's result is cached there under a key made
#' of its parameters and its input's key, rooted at the snapshot (adr/0021).
#' Stores the steps create are written to the project's vault. Nothing runs
#' until a step is run or a parameter changed. Showing another object in the
#' viewer ends the analysis.
#'
#' Use it through [LensViewer] `$analysis()`.
#'
#' @export
LensAnalysis <- R6::R6Class("LensAnalysis",
    public = list(
        #' @field status Per step: `status` (`"stale"`, `"running"`, `"done"`,
        #'   `"error"`, `"blocked"`), `secs`, `summary`, `message`
        status = NULL,

        #' @description Set up the analysis of the object shown. Use
        #'   [LensViewer] `$analysis()` instead.
        #' @param viewer The [LensViewer]
        #' @param x The giotto object shown, loaded from its snapshot
        #' @param host What the viewer gives the analysis (internal): its jobs
        #'   (`start_job()`, `cancel()`, `progress_file()`), `columns(df)` to
        #'   keep its columns in the metadata, `color_item(key, done)` and
        #'   `root`, the snapshot's key
        #' @param params,cell_markers,threads,analyses,network_dir See
        #'   [LensViewer] `$analysis()`
        #' @param spat_unit,feat_type Spatial unit and feature type
        initialize = function(viewer, x, host, params = NULL, cell_markers = NULL, threads = 4L,
                              analyses = character(),
                              spat_unit = "cell", feat_type = "rna",
                              network_dir = .default_network_dir()) {
            private$viewer <- viewer
            private$host <- host
            private$root <- host$root
            private$catalog_ <- .analysis_catalog()
            analyses <- as.character(unlist(analyses))
            bad <- setdiff(analyses, names(private$catalog_))
            if (length(bad))
                stop("[LensAnalysis] no analysis ", paste0("'", bad, "'", collapse = ", "),
                    "; analyses: ", paste(names(private$catalog_), collapse = ", "),
                    call. = FALSE)
            raw <- GiottoClass::getExpression(x, values = "raw", spat_unit = spat_unit,
                feat_type = feat_type, output = "exprObj")[]
            private$disk <- inherits(raw, "parquetExprStore")
            private$x_names <- list(spat_unit = spat_unit, feat_type = feat_type)
            private$obj_values <- tryCatch(as.character(GiottoClass::list_expression_names(x,
                spat_unit = spat_unit, feat_type = feat_type)), error = function(e) "raw")
            private$obj_networks <- tryCatch(as.character(
                GiottoClass::list_spatial_networks_names(x, spat_unit = spat_unit)),
                error = function(e) character())
            for (id in unique(c("preprocess", analyses))) private$include(id)
            private$markers_in <- .parse_markers(cell_markers)
            private$meta <- data.frame(cell_ID = as.character(GiottoClass::spatIDs(x,
                spat_unit = spat_unit)))
            private$obj_meta <- .categorical_columns(as.data.frame(GiottoClass::pDataDT(x,
                spat_unit = spat_unit, feat_type = feat_type)))
            if (length(params)) for (s in names(params)) for (k in names(params[[s]]))
                private$check_set(s, k, params[[s]][[k]])
            private$update_keys()
            if (!is.null(network_dir) && (!is.character(network_dir) ||
                    length(network_dir) != 1L || is.na(network_dir)))
                stop("[LensAnalysis] `network_dir` must be one folder or NULL", call. = FALSE)
            private$network_dir <- network_dir
            private$threads <- as.integer(threads)
            private$worker <- .AnalysisWorker$new(host)
        },

        #' @description The job that reads an item key made here, for a gene
        #'   from a result table (internal; the viewer's item reads)
        #' @param item An item key
        item_job = function(item) {
            ref <- private$item_keys[[item]]
            if (is.null(ref)) return(NULL)
            list(label = paste("read", ref$feat), fun = .aw_item,
                args = list(key = ref$key, feat = ref$feat, values = ref$values))
        },

        #' @description Whether the analysis has work to keep: a step that ran
        #'   (internal; what `set_object()` will not drop without `discard`)
        has_work = function() any(vapply(self$status, function(st)
            identical(st$status, "done"), NA)),

        #' @description Parameter values as R values, by step
        params = function() {
            lapply(stats::setNames(names(private$steps), names(private$steps)), function(s)
                private$r_values(s))
        },

        #' @description Set parameters; affected steps of the Preprocessing
        #'   tab rerun, those of the other tabs wait for `run()`
        #' @param step Step id (`names(viewer$analysis()$params())`)
        #' @param ... `parameter = value` pairs: a menu choice, or for a number
        #'   parameter any number in its range
        set = function(step, ...) {
            vals <- list(...)
            for (k in names(vals)) private$check_set(step, k, vals[[k]])
            private$started <- TRUE
            private$changed()
            if (private$viewer$connected())
                private$viewer$send("analysis_schema", private$schema())
            invisible(self)
        },

        #' @description Run the stale steps of an analysis, or one step and the
        #'   stale steps above it
        #' @param pipeline Analysis id (`names(viewer$analysis()$analyses())`);
        #'   ignored when `step` is given
        #' @param step Step id; `NULL` for every step of the analysis
        run = function(pipeline = "preprocess", step = NULL) {
            private$started <- TRUE
            if (!is.null(step)) {
                st <- private$steps[[step]]
                if (is.null(st)) stop("[LensAnalysis] no step '", step, "'", call. = FALSE)
                todo <- character()
                a <- step
                while (!is.null(a) && identical(private$steps[[a]]$pipeline, st$pipeline)) {
                    todo <- c(a, todo)
                    a <- private$input_of(a)
                }
            } else {
                private$check_pipeline(pipeline)
                todo <- private$pipelines[[pipeline]]$steps
            }
            for (s in todo) if (private$stale(s) && !private$auto(s) &&
                                !identical(self$status[[s]]$status, "running")) {
                private$requested[[s]] <- private$keys[[s]]
                self$status[[s]] <- list(status = "queued")
            }
            private$send_status()
            private$tick()
            invisible(self)
        },

        #' @description The analyses that can be added: id, label, brief and
        #'   whether it is included
        catalog = function() {
            data.frame(id = names(private$catalog_),
                label = vapply(private$catalog_, `[[`, "", "label"),
                brief = vapply(private$catalog_, function(e) e$brief %||% "", ""),
                included = names(private$catalog_) %in% names(private$pipelines),
                row.names = NULL)
        },

        #' @description The included analyses: id -> step ids
        analyses = function() lapply(private$pipelines, `[[`, "steps"),

        #' @description Add an analysis; its steps wait for `run()`
        #' @param id An id from `catalog()`
        #' @param params Starting values for its steps, as in
        #'   [LensViewer] `$analysis()`
        add = function(id, params = NULL) {
            if (!is.character(id) || length(id) != 1L || is.null(private$catalog_[[id]]))
                stop("[LensAnalysis] no analysis '", paste(id, collapse = ", "), "'; analyses: ",
                    paste(names(private$catalog_), collapse = ", "), call. = FALSE)
            private$include(id)
            for (s in intersect(names(params), private$pipelines[[id]]$steps))
                for (k in names(params[[s]])) private$check_set(s, k, params[[s]][[k]])
            private$changed()
            private$send_schema()
            invisible(self)
        },

        #' @description Remove an analysis; its history is kept and comes back
        #'   when it is added again
        #' @param id An included analysis other than `"preprocess"`
        remove = function(id) {
            private$check_pipeline(id)
            if (identical(id, "preprocess"))
                stop("[LensAnalysis] Preprocessing cannot be removed", call. = FALSE)
            steps <- private$pipelines[[id]]$steps
            r <- private$running
            if (!is.null(r$step) && r$step %in% steps) private$interrupt()
            private$drop_cols(steps)
            for (pn in unlist(lapply(steps, function(s) private$panels_of[[s]])))
                try(private$viewer$remove_panel(pn), silent = TRUE)
            private$panels_of[steps] <- NULL
            private$tables[steps] <- NULL
            private$results[steps] <- NULL
            private$requested[steps] <- NULL
            private$done[steps] <- NULL
            private$steps[steps] <- NULL
            self$status[steps] <- NULL
            private$pipelines[[id]] <- NULL
            private$update_keys()
            private$send_status()
            private$send_schema()
            private$send_tables()
            invisible(self)
        },

        #' @description Finished runs kept for the session
        #' @param id An analysis id; `NULL` for all
        history = function(id = NULL) {
            ids <- if (is.null(id)) names(private$runs) else id
            rows <- lapply(ids, function(k) {
                runs <- private$runs[[k]]
                if (!length(runs)) return(NULL)
                data.frame(analysis = k, run = vapply(runs, `[[`, 0L, "n"),
                    time = vapply(runs, `[[`, "", "time"),
                    summary = vapply(runs, `[[`, "", "label"),
                    current = vapply(runs, function(r) private$is_current(k, r), NA))
            })
            out <- do.call(rbind, rows)
            if (is.null(out)) data.frame(analysis = character(), run = integer(),
                time = character(), summary = character(), current = logical()) else out
        },

        #' @description Bring back a run from `history()`: its parameters and
        #'   results, without running the steps
        #' @param id Analysis id
        #' @param run Run number from `history()`
        restore_run = function(id, run) {
            private$check_pipeline(id)
            rec <- Find(function(r) identical(r$n, as.integer(run)), private$runs[[id]])
            if (is.null(rec))
                stop("[LensAnalysis] no run ", run, " of '", id, "'", call. = FALSE)
            for (s in names(rec$values)) private$values[[s]] <- rec$values[[s]]
            if (identical(id, "preprocess")) {
                private$region_ids <- rec$region
                private$cluster_labels <- rec$labels
                private$inherited <- rec$inherited
                private$suggested <- rec$suggested
                private$suggestions <- rec$suggestions
            }
            private$update_keys()
            if (identical(id, "preprocess")) private$save_labels()
            for (s in private$pipelines[[id]]$steps) {
                if (!identical(private$keys[[s]], rec$keys[[s]]) || is.null(rec$results[[s]]))
                    next
                private$done[[s]] <- rec$keys[[s]]
                private$requested[[s]] <- NULL
                self$status[[s]] <- rec$status[[s]]
                private$results[[s]] <- rec$results[[s]]
                private$show(s, rec$results[[s]]$res)
            }
            private$changed()
            private$send_schema()
            private$send_markers()
            invisible(self)
        },

        #' @description Get or set cell-type labels by Leiden cluster
        #' @param labels Named character vector, cluster -> label; `NULL` to get
        labels = function(labels = NULL) {
            if (is.null(labels)) return(unlist(private$cluster_labels))
            if (!is.character(labels) || is.null(names(labels)))
                stop("[LensAnalysis] `labels` must be a character vector named by cluster",
                    call. = FALSE)
            lab <- private$cluster_labels
            lab[names(labels)] <- as.list(unname(labels))
            private$set_labels(lab)
            private$changed()
            private$send_markers()
            invisible(self)
        },

        #' @description Get or set the marker genes of the Automatic types step
        #' @param x Marker genes, see [LensViewer] `$analysis()`; `NULL` to get
        cell_markers = function(x = NULL) {
            if (is.null(x)) return(private$markers_in)
            private$markers_in <- .parse_markers(x)
            private$changed()
            if (private$viewer$connected())
                private$viewer$send("analysis_schema", private$schema())
            invisible(self)
        },

        #' @description Save the current parameters, marker list and labels
        #'   under a name; the viewer lists it for restoring
        #' @param name Name; an existing name is replaced
        save_settings = function(name) {
            if (!is.character(name) || length(name) != 1L || !nzchar(trimws(name)))
                stop("[LensAnalysis] `name` must be one non-empty string", call. = FALSE)
            private$saved[[trimws(name)]] <- list(time = format(Sys.time(), "%Y-%m-%d %H:%M"),
                values = private$values, cell_markers = private$markers_in,
                analyses = names(private$pipelines),
                region = private$region_ids,
                labels = private$cluster_labels, inherited = private$inherited,
                suggested = private$suggested, suggestions = private$suggestions)
            private$send_schema()
            invisible(self)
        },

        #' @description Go back to saved settings; steps whose parameters
        #'   change rerun
        #' @param name A name from `settings()`
        restore_settings = function(name) {
            set <- private$saved[[name]]
            if (is.null(set))
                stop("[LensAnalysis] no saved settings '", name, "'; saved: ",
                    paste(names(private$saved), collapse = ", "), call. = FALSE)
            for (id in intersect(as.character(unlist(set$analyses)), names(private$catalog_)))
                private$include(id)
            for (s in intersect(names(set$values), names(private$steps)))
                for (k in names(set$values[[s]]))
                    tryCatch(private$check_set(s, k, set$values[[s]][[k]]),
                        error = function(e) warning(conditionMessage(e), call. = FALSE))
            private$markers_in <- set$cell_markers %||% list()
            private$region_ids <- as.character(unlist(set$region))
            private$update_keys()
            private$cluster_labels <- set$labels %||% list()
            private$inherited <- set$inherited %||% list()
            private$suggested <- set$suggested %||% list()
            private$suggestions <- set$suggestions
            private$save_labels()
            private$changed()
            private$send_schema()
            private$send_markers()
            invisible(self)
        },

        #' @description Names and times of the saved settings
        settings = function() {
            data.frame(name = names(private$saved),
                time = vapply(private$saved, `[[`, "", "time"), row.names = NULL)
        },

        #' @description Remove saved settings
        #' @param name A name from `settings()`
        remove_settings = function(name) {
            private$saved[[name]] <- NULL
            private$send_schema()
            invisible(self)
        },

        #' @description Write the saved settings to a JSON file
        #' @param file Path
        write_settings = function(file) {
            sets <- lapply(private$saved, function(x) {
                x$suggestions <- if (!is.null(x$suggestions)) as.list(x$suggestions)
                x
            })
            jsonlite::write_json(list(lens_analysis_settings = 1L, sets = sets), file,
                auto_unbox = TRUE, null = "null", digits = NA, pretty = TRUE)
            invisible(file)
        },

        #' @description Add the settings in a JSON file from `write_settings()`
        #' @param file Path
        read_settings = function(file) {
            j <- jsonlite::read_json(file, simplifyVector = FALSE)
            if (is.null(j$lens_analysis_settings))
                stop("[LensAnalysis] '", file, "' is not a settings file", call. = FALSE)
            for (nm in names(j$sets)) {
                x <- j$sets[[nm]]
                x$cell_markers <- lapply(x$cell_markers, function(g) as.character(unlist(g)))
                x$suggestions <- if (length(x$suggestions))
                    as.data.frame(lapply(x$suggestions, unlist), stringsAsFactors = FALSE)
                for (k in c("labels", "inherited", "suggested", "values"))
                    if (!length(x[[k]])) x[[k]] <- list()
                private$saved[[nm]] <- x
            }
            private$send_schema()
            invisible(self)
        },

        #' @description Get or set the region the steps run on
        #' @param cells Cell IDs; `NULL` or an empty vector for the whole
        #'   tissue. Missing: return the current region (`character(0)` for
        #'   the whole tissue)
        region = function(cells) {
            if (missing(cells)) return(private$region_ids)
            private$region_ids <- sort(unique(as.character(cells)))
            private$changed()
            private$send_schema()
            invisible(self)
        },

        #' @description Wait until no step is running or waiting to run
        #' @param timeout Seconds
        wait = function(timeout = 300) {
            t0 <- Sys.time()
            while (private$busy()) {
                if (as.numeric(Sys.time() - t0, units = "secs") > timeout)
                    stop("[LensAnalysis] steps still running after ", timeout, " s",
                        call. = FALSE)
                later::run_now(0.05)
            }
            invisible(self)
        },

        #' @description The giotto object after the last step, with the UMAP
        #' @param timeout Seconds to wait for running steps
        gobject = function(timeout = 300) {
            self$wait(timeout)
            if (is.null(private$pipelines$preprocess))
                stop("[LensAnalysis] the Preprocessing tab is not open", call. = FALSE)
            last <- utils::tail(private$pipelines$preprocess$steps, 1L)
            private$worker$run(.aw_gobject, list(key = private$keys[[last]],
                umap_key = private$keys[["umap"]], umap_name = private$result_names()$umap),
                label = "analysis: the object")
        },

        #' @description R code that reproduces the current parameters
        #' @param pipeline Analysis id
        code = function(pipeline = "preprocess") {
            private$check_pipeline(pipeline)
            steps <- private$pipelines[[pipeline]]$steps
            out <- c(paste0("activeSpatUnit(g) <- ", .code_value(private$x_names$spat_unit)),
                paste0("activeFeatType(g) <- ", .code_value(private$x_names$feat_type)))
            for (s in setdiff(steps, if (!length(private$markers_in)) "auto_type")) {
                st <- private$steps[[s]]
                out <- c(out, if (is.function(st$code))
                    st$code(private$r_values(s, up = FALSE), private$r_values(s)$up)
                else .step_code(s, private$r_values(s, up = FALSE),
                    private$r_values(s)$up, unlist(private$cluster_labels), private$region_ids))
            }
            paste(out[nzchar(out)], collapse = "\n")
        },

        #' @description Color the cells by the cell type column of a Spatial
        #'   interactions analysis and draw only cell types `a` and `b`, as a
        #'   click on its proximity heatmap does
        #' @param a,b Cell types; `b = a` shows one type
        #' @param step A step with a cell type step above it
        show_pair = function(a, b = a, step = "proximity") {
            if (is.null(private$steps[[step]]))
                stop("[LensAnalysis] no step '", step, "'; add the analysis first", call. = FALSE)
            private$focus_pair(step, c(as.character(a), as.character(b)))
            invisible(self)
        },

        #' @description Score a set of genes per cell on the result of a step,
        #'   as dragging across genes in the co-expression heatmap does: the mean
        #'   of the genes' values (z-scored first when the step's module score is
        #'   `"zmean"`), added as cell metadata `cm_meta_<n>` and colored by
        #' @param genes Gene names
        #' @param step A step that has run, by default the co-expression modules
        score_genes = function(genes, step = "cm_modules") {
            genes <- unique(as.character(unlist(genes)))
            if (!length(genes)) stop("[LensAnalysis] no genes", call. = FALSE)
            if (is.null(private$steps[[step]]))
                stop("[LensAnalysis] no step '", step, "'; add the analysis first", call. = FALSE)
            if (private$stale(step))
                stop("[LensAnalysis] step '", step, "' has no current result; run it first",
                    call. = FALSE)
            p <- private$r_values(step)
            private$gene_sets <- c(private$gene_sets, list(list(step = step, genes = genes,
                values = if (isTRUE(p$up$normalize$scale)) "scaled" else "normalized",
                stat = p$score_stat %||% "mean")))
            private$tick()
            invisible(self)
        },

        #' @description Stop the running step (its job is cancelled) and drop
        #'   pending runs; stale steps of added analyses wait for `run()`,
        #'   those of Preprocessing run again
        cancel = function() {
            private$requested <- list()
            for (s in names(private$steps))
                if (identical(self$status[[s]]$status, "queued"))
                    self$status[[s]] <- list(status = "stale")
            private$interrupt()
            private$send_status()
            invisible(self)
        },

        #' @description Expression names the Normalize step's result has: the
        #'   input object's, with `"normalized"`, and `"scaled"` when it z-score
        #'   scales (internal; listed by the viewer's "values" menus)
        expression_names = function() {
            unique(c(private$obj_values, "normalized",
                if (identical(private$values$normalize$scale, "TRUE")) "scaled"))
        },

        #' @description End the analysis: its running step is cancelled. What
        #'   it holds in the jobs' daemon is dropped when another object is
        #'   shown or the viewer closes (internal; called by the viewer).
        close = function() {
            if (is.function(private$timer)) private$timer()
            private$timer <- NULL
            if (!is.null(private$worker)) {
                private$worker$interrupt()
                private$worker <- NULL
            }
            invisible(self)
        },

        #' @description Handle a message from the viewer (internal)
        #' @param type Message type
        #' @param data Payload
        handle = function(type, data) {
            switch(type,
                analysis_param = {
                    tryCatch(private$check_set(as.character(data$step),
                        as.character(data$param), as.character(data$value %||% "")),
                        error = function(e) {
                            if (private$viewer$connected())
                                private$viewer$send("analysis_schema", private$schema())
                            stop(e)
                        })
                    private$started <- TRUE
                    private$changed()
                },
                analysis_labels = {
                    private$set_labels(as.list(unlist(data$labels %||% list())))
                    private$changed()
                },
                analysis_cancel = self$cancel(),
                panel_pick = private$pick(as.character(data$id %||% ""), data$value),
                analysis_run = self$run(pipeline = as.character(data$pipeline %||% ""),
                    step = if (length(data$step)) as.character(data$step)),
                analysis_add = {
                    id <- as.character(data$id %||% "")
                    params <- lapply(data$params %||% list(), function(x) lapply(x, unlist))
                    private$include(id = id, check = TRUE)
                    errs <- character()
                    for (s in intersect(names(params), private$pipelines[[id]]$steps))
                        for (k in names(params[[s]])) tryCatch(
                            private$check_set(s, k, as.character(params[[s]][[k]])),
                            error = function(e) errs <<- c(errs, conditionMessage(e)))
                    private$changed()
                    private$send_schema()
                    if (length(errs)) stop(paste(errs, collapse = "; "), call. = FALSE)
                },
                analysis_remove = self$remove(as.character(data$id %||% "")),
                analysis_history = self$restore_run(as.character(data$id %||% ""),
                    as.integer(data$run %||% NA)),
                analysis_feature = private$want_feature(as.character(data$step %||% ""),
                    as.character(data$feat %||% "")),
                analysis_region = switch(as.character(data$action %||% ""),
                    selection = {
                        sel <- private$viewer$selection
                        if (!length(sel))
                            stop("select cells first (lasso, polygon or rectangle)", call. = FALSE)
                        self$region(sel)
                    },
                    all = self$region(NULL),
                    stop("unknown region action", call. = FALSE)),
                analysis_settings = switch(as.character(data$action %||% ""),
                    save = self$save_settings(as.character(data$name %||% "")),
                    restore = self$restore_settings(as.character(data$name %||% "")),
                    remove = self$remove_settings(as.character(data$name %||% "")),
                    stop("unknown settings action", call. = FALSE))
            )
            invisible(self)
        },

        #' @description Send the schema, status and markers to a tab (internal)
        #' @param ws The tab's WebSocket
        on_ready = function(ws) private$send_all(ws$send),

        #' @description Send the schema, status and markers to every tab;
        #'   `open` brings the Analysis panel forward (internal)
        #' @param open Whether tabs open the panel
        announce = function(open = FALSE) {
            v <- private$viewer
            if (v$connected()) private$send_all(function(m) v$send(m$type, m$data),
                open = open, raw = TRUE)
            invisible(self)
        },

        #' @description Print a summary
        #' @param ... Ignored
        print = function(...) {
            cat("LensAnalysis\n")
            for (s in names(private$steps)) {
                st <- self$status[[s]]
                cat(sprintf("  %-18s %-8s %s\n", s, st$status,
                    st$summary %||% st$message %||% ""))
            }
            invisible(self)
        }
    ),

    private = list(
        # The analysis's messages, through `send` (encoded unless `raw`)
        send_all = function(send, open = FALSE, raw = FALSE) {
            out <- function(type, data)
                send(if (raw) list(type = type, data = data) else .encode_ws_message(type, data))
            out("analysis_schema", c(private$schema(), if (open) list(open = TRUE)))
            out("analysis_status", list(steps = self$status))
            if (!is.null(private$markers)) out("analysis_markers", private$markers_msg())
            if (!is.null(private$color))
                out("analysis_color", if (identical(private$pair$column, private$color))
                    private$pair else list(column = private$color))
            out("analysis_tables", private$tables_msg())
        },
        viewer = NULL, steps = NULL, dir = NULL, disk = FALSE, values = NULL,
        keys = NULL, done = list(), worker = NULL, running = NULL,
        cancelled = FALSE, cluster_labels = list(), meta = NULL, markers = NULL,
        colored = FALSE, color = NULL, timer = NULL, recent = character(),
        cols = list(), debounce = NULL, info = NULL, meta_timer = NULL,
        label_store = list(), inherited = list(), snap = NULL, n_pcs = NULL, saved = list(),
        region_ids = character(), jobs = list(), x_names = NULL, sent_values = NULL,
        markers_in = list(), suggested = list(), suggestions = NULL,
        pipelines = list(), requested = list(), obj_meta = NULL, group_cache = list(),
        group_cols = NULL, catalog_ = NULL, tables = list(), results = list(), runs = list(),
        run_seq = 0L, active = FALSE, panels_of = list(),
        network_dir = NULL, threads = 4L, progress_seen = NULL,
        host = NULL, root = NULL, started = FALSE, item_keys = list(),
        pair = NULL, gene_sets = list(), meta_n = 0L, obj_values = NULL, menus_sent = NULL,
        meta_cats = character(), obj_networks = character(),

        check_pipeline = function(id) {
            if (!is.character(id) || length(id) != 1L || is.null(private$pipelines[[id]]))
                stop("[LensAnalysis] no analysis '", paste(id, collapse = ", "),
                    "'; included: ", paste(names(private$pipelines), collapse = ", "),
                    call. = FALSE)
        },

        # Add a catalog entry's steps; values set before are kept
        include = function(id, check = FALSE) {
            ent <- private$catalog_[[id]]
            if (is.null(ent)) stop("[LensAnalysis] no analysis '", id, "'", call. = FALSE)
            if (!is.null(private$pipelines[[id]])) return(invisible())
            private$pipelines[[id]] <- list(label = ent$label, auto = isTRUE(ent$auto),
                steps = names(ent$steps))
            defaults <- private$default_values(ent$steps)
            for (s in names(ent$steps)) {
                private$steps[[s]] <- ent$steps[[s]]
                if (is.null(private$values[[s]])) private$values[[s]] <- defaults[[s]]
                self$status[[s]] <- list(status = "stale")
            }
            if (!is.null(private$meta)) private$update_keys()
        },

        # Default values of `steps`; a network step takes a spatial network
        # of the loaded object (.preferred_network())
        default_values = function(steps) {
            d <- .default_values(steps, private$disk)
            net <- .preferred_network(private$obj_networks)
            if (!is.null(net)) for (s in names(d))
                if (identical(d[[s]]$network, "new")) d[[s]]$network <- net
            d
        },

        # The step a step reads: for a source step, the Preprocessing tab's
        # Cell types step or the loaded object
        input_of = function(s) {
            st <- private$steps[[s]]
            if (identical(st$kind, "source")) {
                if (identical(private$values[[s]]$from %||% "preprocess", "preprocess") &&
                    !is.null(private$steps$labels)) return("labels")
                return(NULL)
            }
            st$input
        },

        # A finished run: when no step of the analysis is stale or running
        record_run = function(id) {
            steps <- private$pipelines[[id]]$steps
            st <- vapply(steps, function(s) self$status[[s]]$status, "")
            if (any(st %in% c("stale", "queued", "running")) || !any(st == "done")) return()
            keys <- private$keys[steps]
            runs <- private$runs[[id]]
            same <- vapply(runs, function(r) identical(r$keys, keys), NA)
            if (any(same)) return()
            private$run_seq <- private$run_seq + 1L
            n <- private$run_seq
            sums <- unlist(lapply(steps, function(s) self$status[[s]]$summary))
            rec <- list(n = n, time = format(Sys.time(), "%H:%M:%S"), keys = keys,
                values = private$values[steps], status = self$status[steps],
                results = private$results[steps],
                label = paste(utils::tail(sums[nzchar(sums)], 2L), collapse = "; "),
                params = .param_lines(private$steps[steps], private$values[steps]))
            if (identical(id, "preprocess")) {
                rec$region <- private$region_ids; rec$labels <- private$cluster_labels
                rec$inherited <- private$inherited; rec$suggested <- private$suggested
                rec$suggestions <- private$suggestions
            }
            runs <- c(runs, list(rec))
            cap <- getOption("GiottoLens.analysis_history", 10L)
            private$runs[[id]] <- utils::tail(runs, cap)
            private$send_schema()
        },

        is_current = function(id, rec) identical(rec$keys, private$keys[names(rec$keys)]) &&
            all(vapply(names(rec$keys), function(s) !private$stale(s), NA)),

        # A gene from a table row: its expression as a metadata column, once the
        # worker is free
        # A gene from a table row or a pick: the cells are coloured by it,
        # read as an item (adr/0024) from the first of the step, Cell types and
        # Normalize whose result is current, by that result's key, so the
        # values never change under the key (adr/0021)
        want_feature = function(step, feat) {
            if (!nzchar(feat)) stop("no feature", call. = FALSE)
            cand <- intersect(c(step, "labels", "normalize"), names(private$steps))
            cand <- cand[!vapply(cand, private$stale, NA)]
            key <- if (length(cand)) private$keys[[cand[[1L]]]] else private$root
            values <- .values_of(private$r_values(step))
            item <- .item_key("expression", private$x_names$feat_type, feat, name = values,
                method = paste0("analysis:", .key_hash(key)))
            private$item_keys[[item]] <- list(key = key, feat = feat, values = values)
            private$host$color_item(item, function(r) if (private$viewer$connected())
                private$viewer$send("analysis_feature",
                    if (!is.null(r$error)) list(feat = feat, error = r$error)
                    else list(feat = feat, column = item, values = values)))
        },


        tables_msg = function() list(tables = if (length(private$tables)) private$tables
            else structure(list(), names = character())),

        send_tables = function() {
            if (private$viewer$connected())
                private$viewer$send("analysis_tables", private$tables_msg())
        },

        interrupt = function() {
            r <- private$running
            if (!is.null(r$key)) {
                private$worker$interrupt()
                private$cancelled <- TRUE
            }
        },

        # Set up the daemon's side of the analysis (.aw_init()) before its
        # first job; it is set up again if the daemon lost it
        start_worker = function() {
            private$running <- list(step = ".init")
            private$worker$call(.aw_init, list(root = private$root,
                spat_unit = private$x_names$spat_unit, feat_type = private$x_names$feat_type,
                threads = private$threads, network_dir = private$network_dir,
                cap_mb = getOption("GiottoLens.analysis_cache_mb", 4096),
                helpers = .aw_helpers()), label = "analysis: set up")
        },

        progress_file = function() private$worker$progress_file(),

        # Sends the running step's progress when the worker wrote new progress
        poll_progress = function() {
            r <- private$running
            if (is.null(r$key)) return(invisible())
            f <- private$progress_file()
            mt <- suppressWarnings(file.mtime(f))
            if (is.na(mt) || identical(private$progress_seen, mt)) return(invisible())
            private$progress_seen <- mt
            x <- tryCatch(strsplit(readLines(f, n = 1L, warn = FALSE), "\t")[[1L]],
                error = function(e) NULL)
            if (length(x) < 2L) return(invisible())
            pr <- list(done = as.numeric(x[[1L]]), total = as.numeric(x[[2L]]),
                what = if (length(x) > 2L) x[[3L]] else "")
            if (!is.finite(pr$done) || !is.finite(pr$total) || pr$total <= 0)
                return(invisible())
            self$status[[r$step]]$progress <- pr
            if (private$viewer$connected())
                private$viewer$send("analysis_progress", c(list(step = r$step,
                    elapsed = as.numeric(difftime(Sys.time(), r$t0, units = "secs"))), pr))
        },

        # A click on a point of a step's chart: the step's `pick()` asks for a
        # gene (`feature`), a pair of cell types (`pair`), a metadata column to
        # color by (`color`), genes to score as one set (`genes`) or parameter
        # values of the step (`set`), which are set and the step run
        pick = function(id, value) {
            s <- Find(function(k) id %in% private$panels_of[[k]], names(private$panels_of))
            st <- if (!is.null(s)) private$steps[[s]]
            if (is.null(st) || !is.function(st$pick) || is.null(private$results[[s]]))
                return(invisible())
            act <- st$pick(value, private$results[[s]]$res, private$r_values(s))
            f <- act$feature
            if (is.character(f) && length(f) == 1L && !is.na(f) && nzchar(f))
                private$want_feature(s, f)
            if (is.character(act$pair) && length(act$pair) == 2L && !anyNA(act$pair))
                private$focus_pair(s, act$pair)
            col <- act$color
            if (is.character(col) && length(col) == 1L && col %in% names(private$meta))
                private$set_color(col)
            if (!is.null(act$genes)) {
                err <- if (!length(act$genes)) "no genes under the box"
                    else tryCatch({
                        self$score_genes(act$genes, step = s)
                        NULL
                    }, error = function(e) sub("^\\[[^]]*\\] ", "", conditionMessage(e)))
                if (!is.null(err) && private$viewer$connected())
                    private$viewer$send("analysis_feature", list(feat = "gene set", error = err))
            }
            if (length(act$set)) {
                for (k in names(act$set))
                    private$check_set(s, k, as.character(act$set[[k]]))
                private$changed()
                if (private$viewer$connected())
                    private$viewer$send("analysis_schema", private$schema())
                if (!private$auto(s)) self$run(pipeline = private$steps[[s]]$pipeline, step = s)
            }
            invisible()
        },

        # Colors the cells by the cell type column of the groups step above
        # `s`, drawing only the types in `pair`; a column of the loaded object
        # is added to the metadata first
        focus_pair = function(s, pair) {
            g <- s
            while (!is.null(g) && !identical(private$steps[[g]]$kind, "groups"))
                g <- private$input_of(g)
            if (is.null(g)) stop("no cell type step above '", s, "'", call. = FALSE)
            key <- private$resolve_column(g)
            col <- sub("^(analysis|object):", "", key)
            if (startsWith(key, "object:")) {
                d <- private$group_values(key)
                if (is.null(d)) stop("no column '", col, "'", call. = FALSE)
                taken <- setdiff(names(private$meta), c("cell_ID", private$cols[[".pair"]]))
                name <- if (col %in% taken) paste0("object_", col) else col
                m <- data.frame(cell_ID = as.character(d$cell_ID))
                m[[name]] <- as.character(d$group)
                private$merge_meta(m, ".pair")
                col <- name
            }
            private$pair <- list(column = col, focus = as.list(unique(as.character(pair))))
            private$color <- col
            if (private$viewer$connected()) private$viewer$send("analysis_color", private$pair)
        },

        # Preprocessing runs by itself once the analysis is started: by a run,
        # a parameter set, or a change in the viewer
        auto = function(s) private$started &&
            isTRUE(private$pipelines[[private$steps[[s]]$pipeline]]$auto),

        # Whether a stale step may run now: always in an auto tab, else when
        # run() asked for its current parameters
        wanted = function(s) private$auto(s) ||
            identical(private$requested[[s]], private$keys[[s]]),

        idle_status = function(s)
            if (!private$auto(s) && private$wanted(s)) "queued" else "stale",

        # Names of the Preprocessing results (see .pre_names())
        result_names = function() .pre_names(lapply(stats::setNames(
            c("pca", "umap", "network", "leiden", "auto_type", "labels"),
            c("pca", "umap", "network", "leiden", "auto_type", "labels")), function(s)
            if (!is.null(private$steps[[s]])) private$r_values(s, up = FALSE))),

        # Cell type columns as menu keys: "analysis:<col>" for categorical
        # columns the analyses added, "object:<col>" for those of the loaded
        # object
        group_columns = function() {
            nm <- private$result_names()
            ac <- unique(c(intersect(c(nm$labels, nm$leiden, "cell_type_auto"), private$meta_cats),
                setdiff(private$meta_cats, "qc_pass")))
            ac <- ac[vapply(ac, function(k) any(!is.na(private$meta[[k]])), NA)]
            c(if (length(ac)) paste0("analysis:", ac),
              if (length(private$obj_meta)) paste0("object:", setdiff(names(private$obj_meta),
                  "cell_ID")))
        },

        # The analysis that added metadata column `col`
        column_source = function(col) {
            s <- Find(function(k) col %in% private$cols[[k]], names(private$cols))
            pl <- if (!is.null(s) && !is.null(private$steps[[s]])) private$steps[[s]]$pipeline
            if (is.null(pl)) "Preprocessing" else private$pipelines[[pl]]$label %||% pl
        },

        # The column of a groups step; a bare name or no value takes the
        # Preprocessing tab's column first, or the object's when the analysis
        # reads the loaded object
        resolve_column = function(s) {
            v <- private$values[[s]]$column %||% ""
            cols <- private$group_columns()
            if (v %in% cols) return(v)
            src <- c("analysis:", "object:")
            a <- if (!is.null(private$steps[[s]])) private$input_of(s)
            while (!is.null(a)) {
                if (identical(private$steps[[a]]$kind, "source") &&
                    identical(private$values[[a]]$from, "object")) src <- rev(src)
                a <- private$input_of(a)
            }
            if (nzchar(v)) {
                hit <- intersect(paste0(src, v), cols)
                return(if (length(hit)) hit[[1L]] else v)
            }
            nm <- private$result_names()
            pick <- intersect(c(paste0(src, nm$labels), paste0(src, "cell_type"),
                paste0(src, nm$leiden), paste0(src, "leiden_clus")), cols)
            if (length(pick)) pick[[1L]] else if (length(cols)) cols[[1L]] else ""
        },

        group_values = function(key) {
            col <- sub("^(analysis|object):", "", key)
            if (startsWith(key, "analysis:") && col %in% names(private$meta))
                return(data.frame(cell_ID = private$meta$cell_ID,
                    group = as.character(private$meta[[col]])))
            if (startsWith(key, "object:") && col %in% names(private$obj_meta))
                return(data.frame(cell_ID = private$obj_meta$cell_ID,
                    group = private$obj_meta[[col]]))
            NULL
        },

        group_data = function(s) {
            d <- private$group_values(private$resolve_column(s))
            if (is.null(d)) return(NULL)
            d[!is.na(d$group) & nzchar(d$group), , drop = FALSE]
        },

        # A key for the values of the chosen column, cached on the values
        group_sig = function(s) {
            key <- private$resolve_column(s)
            d <- private$group_values(key)
            if (is.null(d)) return("")
            gc <- private$group_cache[[key]]
            if (!is.null(gc) && identical(gc$group, d$group)) return(gc$sig)
            sig <- .ids_key(paste(d$cell_ID, d$group, sep = "\t"))
            private$group_cache[[key]] <- list(group = d$group, sig = sig)
            sig
        },

        group_steps = function() names(private$steps)[vapply(private$steps, function(st)
            identical(st$kind, "groups"), NA)],

        # After the analysis metadata changes: new column choices and new
        # cell types mark the Spatial interactions steps stale
        refresh_groups = function() {
            gs <- private$group_steps()
            if (!length(gs)) return(invisible())
            cols <- private$group_columns()
            if (!identical(cols, private$group_cols)) {
                private$group_cols <- cols
                private$send_schema()
            }
            old <- private$keys[gs]
            private$update_keys()
            if (identical(old, private$keys[gs])) return(invisible())
            private$requested <- Filter(Negate(is.null), lapply(
                stats::setNames(names(private$requested), names(private$requested)),
                function(k) if (identical(private$requested[[k]], private$keys[[k]]))
                    private$requested[[k]]))
            for (s in unique(unlist(lapply(gs, private$below))))
                if (private$stale(s) && !identical(self$status[[s]]$status, "running"))
                    self$status[[s]] <- list(status = private$idle_status(s))
            r <- private$running
            if (!is.null(r$key) && !identical(private$keys[[r$step]], r$key)) private$interrupt()
            private$send_status()
        },

        check_set = function(step, param, value) {
            st <- private$steps[[step]]
            if (is.null(st))
                stop("[LensAnalysis] no step '", step, "'", call. = FALSE)
            par <- Find(function(q) identical(q$id, param), st$params)
            if (is.null(par))
                stop("[LensAnalysis] step '", step, "' has no parameter '", param, "'",
                    call. = FALSE)
            key <- tryCatch(.param_key(par, value, private$disk, private$max_pcs()),
                error = function(e)
                stop("[LensAnalysis] ", step, "$", param, " ", conditionMessage(e),
                    call. = FALSE))
            old <- private$values[[step]][[param]]
            private$values[[step]][[param]] <- key
            r <- private$results[[step]]
            if (isTRUE(par$view) && !identical(old, key) && !is.null(r) &&
                identical(r$key, private$keys[[step]]) && !private$stale(step))
                private$show(step, r$res)
        },

        # The last PC a range may use: the components PCA returned, else ncp
        max_pcs = function() {
            ncp <- suppressWarnings(as.integer(private$values$pca$ncp))
            if (!is.null(private$n_pcs) && identical(private$done[["pca"]], private$keys[["pca"]]))
                min(private$n_pcs, ncp) else ncp
        },

        # Labels by cluster for the current clustering; a label that changes is
        # no longer marked as carried over
        set_labels = function(lab) {
            lab <- lab[nzchar(trimws(unlist(lab)))]
            old <- private$cluster_labels
            same <- function(marks) marks[vapply(names(marks), function(k)
                identical(old[[k]], lab[[k]]), NA)]
            private$inherited <- same(private$inherited)
            private$suggested <- same(private$suggested)
            private$cluster_labels <- lab
            private$save_labels()
        },

        save_labels = function() {
            private$label_store[[private$keys[["leiden"]]]] <- list(
                labels = private$cluster_labels, inherited = private$inherited,
                suggested = private$suggested, suggestions = private$suggestions)
        },

        # Suggestions from the Automatic types step: they fill clusters with no
        # label and replace earlier suggestions; typed and carried-over labels stay
        set_suggestions = function(sug) {
            lab <- private$cluster_labels
            for (k in names(private$suggested)) lab[[k]] <- NULL
            sugd <- list()
            if (!is.null(sug)) for (i in seq_len(nrow(sug))) {
                k <- as.character(sug$cluster[[i]])
                if (is.null(lab[[k]])) {
                    lab[[k]] <- as.character(sug$type[[i]])
                    sugd[[k]] <- list(type = lab[[k]], share = sug$share[[i]])
                }
            }
            private$cluster_labels <- lab
            private$suggested <- sugd
            private$suggestions <- sug
            private$save_labels()
            private$update_keys()
            private$send_markers()
        },

        # Labels for new clusters from the clustering they were given on: the
        # old cluster holding more than half of a new cluster's cells
        carry_labels = function(new) {
            if (is.null(private$snap)) return(invisible())
            old <- private$label_store[[private$snap$key]]
            old_lab <- old$labels[setdiff(names(old$labels), names(old$suggested))]
            if (!length(old_lab)) return(invisible())
            m <- merge(private$snap$cl, new, by = "cell_ID", suffixes = c("_old", ""))
            lab <- list(); inh <- list()
            for (k in unique(as.character(m$leiden_clus))) {
                tab <- table(as.character(m$leiden_clus_old[m$leiden_clus == k]))
                j <- names(tab)[which.max(tab)]
                share <- max(tab) / sum(tab)
                if (share > 0.5 && !is.null(old_lab[[j]])) {
                    lab[[k]] <- old_lab[[j]]
                    inh[[k]] <- list(from = j, share = round(share, 2))
                }
            }
            private$cluster_labels <- lab
            private$inherited <- inh
            private$suggested <- list()
            private$suggestions <- NULL
            private$save_labels()
            private$update_keys()
        },

        r_values = function(step, up = TRUE) {
            st <- private$steps[[step]]
            p <- list()
            for (par in st$params) {
                key <- private$values[[step]][[par$id]]
                p[par$id] <- list(if (identical(par$type, "values"))
                    private$resolve_values(step, par) else .param_r(par, key))
            }
            if (step == "labels") p$labels <- private$cluster_labels
            if (step == "auto_type" || isTRUE(st$markers)) p$cell_markers <- private$markers_in
            if (step == "region") p$cells <- private$region_ids
            if (identical(st$kind, "groups")) {
                p$column <- private$resolve_column(step)
                p$column_name <- sub("^(analysis|object):", "", p$column)
                p$cells <- private$region_ids
            }
            if (up) {
                p$up <- list()
                a <- private$input_of(step)
                while (!is.null(a)) {
                    p$up[[a]] <- private$r_values(a, up = FALSE)
                    a <- private$input_of(a)
                }
            }
            p
        },

        update_keys = function() {
            first <- private$step_keys(list())
            private$keys <- private$step_keys(first)
        },

        # Keys of all steps, rooted at the snapshot's (adr/0021); a step that
        # uses a spatial network another step makes includes that step's key
        # in `prev`
        step_keys = function(prev) {
            keys <- list()
            ses <- private$session_networks()
            for (s in names(private$steps)) {
                parent <- private$input_of(s)
                own <- private$values[[s]]
                vals <- private$values[[s]]
                vp <- vapply(private$steps[[s]]$params, function(q)
                    isTRUE(q$view) || !.param_shown(q, vals), NA)
                if (any(vp)) own[vapply(private$steps[[s]]$params[vp], `[[`, "", "id")] <- NULL
                if (s == "labels") own$labels <- private$cluster_labels
                for (q in private$steps[[s]]$params) if (identical(q$type, "values"))
                    own[[q$id]] <- private$resolve_values(s, q)
                if (s == "auto_type" || isTRUE(private$steps[[s]]$markers))
                    own$cell_markers <- private$markers_in
                if (s == "region") own$cells <- .ids_key(private$region_ids)
                if (identical(private$steps[[s]]$kind, "groups")) {
                    own$column <- private$resolve_column(s)
                    own$data <- private$group_sig(s)
                    own$cells <- .ids_key(private$region_ids)
                }
                net <- own$network
                if (is.character(net) && !identical(net, "new") &&
                        !net %in% private$obj_networks) {
                    src <- Find(function(x) identical(x$name, net) && x$step != s, ses)
                    if (!is.null(src)) own$network_src <- prev[[src$step]] %||% src$step
                }
                keys[[s]] <- paste0(s, "{", jsonlite::toJSON(own, auto_unbox = TRUE),
                    "}<", if (!is.null(parent)) keys[[parent]] else private$root)
            }
            keys
        },

        stale = function(s) !identical(private$done[[s]], private$keys[[s]]),
        busy  = function() !is.null(private$running) || !is.null(private$meta_timer) ||
            length(private$gene_sets) > 0L ||
            any(vapply(names(private$steps), function(s) private$stale(s) &&
                private$wanted(s) &&
                !identical(self$status[[s]]$status, "error") &&
                !identical(self$status[[s]]$status, "blocked"), NA)),

        changed = function() {
            old_leiden <- private$keys[["leiden"]]
            private$update_keys()
            sig <- private$menus_sig()
            if (!identical(sig, private$menus_sent)) {
                private$menus_sent <- sig
                private$send_schema()
            }
            if (!identical(old_leiden, private$keys[["leiden"]])) {
                saved <- private$label_store[[private$keys[["leiden"]]]]
                private$cluster_labels <- saved$labels %||% list()
                private$inherited <- saved$inherited %||% list()
                private$suggested <- saved$suggested %||% list()
                private$suggestions <- saved$suggestions
                private$update_keys()
                private$send_markers()
            }
            private$requested <- private$requested[vapply(names(private$requested),
                function(k) identical(private$requested[[k]], private$keys[[k]]), NA)]
            for (s in names(private$steps)) if (private$stale(s))
                self$status[[s]] <- list(status = private$idle_status(s))
            r <- private$running
            if (!is.null(r$key) && !identical(private$keys[[r$step]], r$key)) private$interrupt()
            private$send_status()
            if (!is.null(private$debounce)) private$debounce()
            private$debounce <- later::later(function() {
                private$debounce <- NULL
                private$tick()
            }, 0.25)
        },

        next_step = function() {
            for (s in names(private$steps)) {
                if (!private$stale(s) || !private$wanted(s)) next
                if (self$status[[s]]$status %in% c("error", "blocked")) next
                parent <- private$input_of(s)
                if (!is.null(parent) && private$stale(parent)) next
                dep <- private$network_dep(s)
                if (!is.null(dep) && private$stale(dep) && private$wanted(dep)) next
                if (s == "auto_type" && !length(private$markers_in)) {
                    self$status[[s]] <- list(status = "blocked", message = paste(
                        "no marker list: viewer$analysis(cell_markers =) or",
                        "viewer$analysis()$cell_markers()"))
                    private$drop_cols(s)
                    private$set_suggestions(NULL)
                    private$send_status()
                    next
                }
                if (identical(private$steps[[s]]$kind, "groups") &&
                    is.null(private$group_data(s))) {
                    self$status[[s]] <- list(status = "blocked", message = paste(
                        "no cell type column: run the Preprocessing tab or load an",
                        "object with a categorical cell metadata column"))
                    private$requested[[s]] <- NULL
                    for (d in setdiff(private$below(s), s)) {
                        private$requested[[d]] <- NULL
                        self$status[[d]] <- list(status = "stale")
                    }
                    private$send_status()
                    next
                }
                return(s)
            }
            NULL
        },

        start = function(s) {
            st <- private$steps[[s]]
            run <- st$run; result <- st$result
            environment(run) <- globalenv(); environment(result) <- globalenv()
            parent <- private$input_of(s)
            for (d in private$below(s)) private$done[[d]] <- NULL
            private$recent <- utils::tail(unique(c(private$recent,
                unname(unlist(private$keys)))), 40L)
            private$running <- list(step = s, key = private$keys[[s]], t0 = Sys.time())
            private$cancelled <- FALSE
            unlink(private$progress_file())
            private$progress_seen <- NULL
            self$status[[s]] <- list(status = "running", elapsed = 0)
            private$send_status()
            p <- private$r_values(s)
            if (identical(st$kind, "groups")) p$groups <- private$group_data(s)
            private$worker$call(.aw_step, list(run = run, result = result,
                key = private$keys[[s]], parent = if (!is.null(parent)) private$keys[[parent]],
                p = p, current = unname(unlist(private$keys)), recent = private$recent),
                label = paste("analysis:", st$label))
        },

        tick = function() {
            if (is.function(private$timer)) private$timer()
            private$timer <- NULL
            if (is.null(private$worker)) return(invisible())
            r <- private$running
            if (!is.null(r)) {
                if (private$worker$poll_process(0) != "ready") {
                    private$poll_progress()
                    private$timer <- later::later(private$tick, 0.1)
                    return(invisible())
                }
                out <- private$worker$read()
                private$running <- NULL
                if (identical(r$step, ".init")) {
                    if (!is.null(out$error)) {
                        for (s in names(private$steps)) self$status[[s]] <- list(
                            status = "error", message = conditionMessage(out$error))
                        private$send_status()
                        warning("[LensAnalysis] the analysis could not be set up: ",
                            conditionMessage(out$error), call. = FALSE)
                        return(invisible())
                    }
                    private$info <- out$result
                } else if (identical(r$step, ".genes")) {
                    private$show_gene_set(r, out)
                } else private$finish(r, out)
            }
            # The daemon's side is set up before the first job
            wants <- length(private$gene_sets) || !is.null(private$next_step())
            if (wants && is.null(private$info)) {
                private$start_worker()
                private$timer <- later::later(private$tick, 0.1)
                return(invisible())
            }
            if (length(private$gene_sets)) {
                j <- private$gene_sets[[1L]]
                private$gene_sets <- private$gene_sets[-1L]
                private$running <- list(step = ".genes", set = j)
                private$worker$call(.aw_gene_set, list(key = private$keys[[j$step]],
                    genes = j$genes, values = j$values, stat = j$stat),
                    label = "analysis: gene set")
                private$timer <- later::later(private$tick, 0.1)
                return(invisible())
            }
            s <- private$next_step()
            if (!is.null(s)) private$start(s)
            if (is.null(private$running)) {
                if (isTRUE(private$active)) for (pl in names(private$pipelines))
                    private$record_run(pl)
                private$active <- FALSE
            } else private$active <- TRUE
            if (!is.null(private$running)) private$timer <- later::later(private$tick, 0.1)
            invisible()
        },

        finish = function(r, out) {
            s <- r$step
            if (!is.null(out$error)) {
                if (private$cancelled || !identical(private$keys[[s]], r$key)) {
                    if (identical(self$status[[s]]$status, "running"))
                        self$status[[s]] <- list(status = private$idle_status(s))
                    private$send_status()
                    return(invisible())
                }
                msg <- conditionMessage(out$error)
                if (!is.null(out$error$parent)) msg <- conditionMessage(out$error$parent)
                if (grepl("lens_missing_input", msg, fixed = TRUE)) {
                    a <- private$input_of(s)
                    # The daemon lost the analysis (restarted): set it up again
                    if (is.null(a)) {
                        private$info <- NULL
                        self$status[[s]] <- list(status = private$idle_status(s))
                        return(invisible())
                    }
                    private$done[[a]] <- NULL
                    if (!private$auto(a)) private$requested[[a]] <- private$keys[[a]]
                    self$status[[s]] <- list(status = private$idle_status(s))
                    return(invisible())
                }
                self$status[[s]] <- list(status = "error", message = msg)
                private$requested[private$below(s)] <- NULL
                if (s == "auto_type") private$set_suggestions(NULL)
                private$block_below(s)
                private$drop_cols(setdiff(private$below(s), s))
                private$send_status()
                return(invisible())
            }
            if (!identical(private$keys[[s]], r$key)) return(invisible())
            private$done[[s]] <- r$key
            private$requested[[s]] <- NULL
            res <- out$result$result
            private$results[[s]] <- list(key = r$key, res = res)
            self$status[[s]] <- list(status = "done", secs = round(out$result$secs, 2),
                summary = res$summary)
            for (d in names(private$steps))
                if (self$status[[d]]$status == "blocked")
                    self$status[[d]] <- list(status = private$idle_status(d))
            private$show(s, res)
            if (!is.null(res$stop_below)) {
                for (d in setdiff(private$below(s), s)) {
                    self$status[[d]] <- list(status = "blocked", message = res$stop_below)
                    private$requested[[d]] <- NULL
                }
                private$drop_cols(setdiff(private$below(s), s))
            }
            private$send_status()
        },

        # A scored gene set as metadata column cm_meta_<n>, colored by
        show_gene_set = function(r, out) {
            if (!is.null(out$error)) {
                msg <- conditionMessage(out$error$parent %||% out$error)
                private$viewer$send("analysis_feature", list(feat = "gene set", error = msg))
                return(invisible())
            }
            d <- out$result
            private$meta_n <- private$meta_n + 1L
            col <- paste0("cm_meta_", private$meta_n)
            m <- data.frame(cell_ID = d$cell_ID)
            m[[col]] <- d$value
            private$merge_meta(m, paste0(".", col))
            private$set_color(col)
            shown <- utils::head(d$genes, 6L)
            private$viewer$send("analysis_feature", list(
                feat = sprintf("%s, %d genes: %s%s", col, length(d$genes),
                    paste(shown, collapse = ", "), if (length(d$genes) > 6L) ", ..." else ""),
                column = col, values = paste(r$set$values, r$set$stat)))
        },

        # The step and every step below it
        below = function(s) {
            out <- s
            repeat {
                more <- setdiff(names(private$steps)[vapply(names(private$steps), function(k) {
                    a <- private$input_of(k)
                    !is.null(a) && a %in% out
                }, NA)], out)
                if (!length(more)) return(out)
                out <- c(out, more)
            }
        },

        drop_cols = function(steps) {
            drop <- unlist(private$cols[steps])
            private$cols[steps] <- NULL
            if (is.null(private$meta) || !length(intersect(drop, names(private$meta))))
                return(invisible())
            private$meta <- private$meta[setdiff(names(private$meta), drop)]
            private$meta_cats <- intersect(private$meta_cats, names(private$meta))
            private$push_meta()
            private$refresh_groups()
        },

        block_below = function(s) {
            for (d in names(private$steps)) {
                a <- private$input_of(d)
                while (!is.null(a)) {
                    if (a == s) { self$status[[d]] <- list(status = "blocked"); break }
                    a <- private$input_of(a)
                }
            }
        },

        # Results to the viewer
        show = function(s, res) {
            v <- private$viewer
            if (!is.null(res$meta)) private$merge_meta(res$meta, s)
            p <- private$r_values(s)
            switch(s,
                filter = {
                    v$push_panel(.qc_hist_spec(res$meta, "qc_nr_feats",
                        "features detected per cell", p$min_det_feats_per_cell),
                        id = "qc-cells", title = "QC: cells")
                    v$push_panel(.qc_hist_spec(res$feats, "nr_cells",
                        "cells detecting the feature", p$feat_det_in_min_cells),
                        id = "qc-feats", title = "QC: features", ref = "qc-cells")
                    if (!private$colored) private$set_color("qc_pass")
                },
                hvf = if (all(c("mean_expr", "cov") %in% names(res$hvf)) ||
                          all(c("mean_expr", "var") %in% names(res$hvf)))
                    v$push_panel(.hvf_spec(res$hvf), id = "hvf", title = "HVF",
                        ref = "qc-cells"),
                pca = {
                    v$push_panel(.elbow_spec(res$elbow), id = "pca-elbow",
                        title = "PCA elbow", ref = "qc-cells")
                    if (!identical(private$n_pcs, nrow(res$elbow))) {
                        private$n_pcs <- nrow(res$elbow)
                        if (v$connected()) v$send("analysis_schema", private$schema())
                    }
                },
                leiden = {
                    nm <- private$result_names()$leiden
                    cl <- data.frame(cell_ID = res$meta$cell_ID, leiden_clus = res$meta[[nm]])
                    if (is.null(private$label_store[[private$keys[["leiden"]]]]))
                        private$carry_labels(cl)
                    private$snap <- list(key = private$keys[["leiden"]], cl = cl)
                    if (!private$colored) {
                        private$colored <- TRUE
                        private$set_color(nm)
                    }
                },
                markers = {
                    private$markers <- res$markers
                    private$send_markers()
                },
                auto_type = private$set_suggestions(res$suggest)
            )
            st <- private$steps[[s]]
            if (is.function(st$view)) {
                out <- st$view(res, p)
                for (pn in out$panels) {
                    v$push_panel(pn$spec, id = pn$id, title = pn$title)
                    private$panels_of[[s]] <- unique(c(private$panels_of[[s]], pn$id))
                }
                if (!is.null(out$tables)) {
                    private$tables[[s]] <- unname(out$tables)
                    private$send_tables()
                }
                if (!is.null(out$color)) private$set_color(out$color)
            }
        },

        merge_meta = function(m, s) {
            m$cell_ID <- as.character(m$cell_ID)
            gone <- setdiff(private$cols[[s]], names(m))
            if (length(gone)) private$meta <- private$meta[setdiff(names(private$meta), gone)]
            private$cols[[s]] <- setdiff(names(m), "cell_ID")
            if (is.null(private$meta)) {
                if (s != "filter") return(invisible())
                private$meta <- m
            } else {
                keep <- setdiff(names(private$meta), setdiff(names(m), "cell_ID"))
                private$meta <- merge(private$meta[keep], m, by = "cell_ID",
                    all.x = TRUE, sort = FALSE)
            }
            private$meta_cats <- .label_columns(private$meta)
            private$push_meta()
            private$refresh_groups()
        },

        # One metadata push for results that arrive close together
        push_meta = function() {
            if (!is.null(private$meta_timer)) return(invisible())
            private$meta_timer <- later::later(function() {
                private$meta_timer <- NULL
                if (!is.null(private$meta))
                    suppressMessages(private$host$columns(private$meta))
            }, 0.3)
        },

        schema = function() {
            list(disk = private$disk, cell_markers = length(private$markers_in),
                region = length(private$region_ids),
                settings = unname(lapply(names(private$saved), function(n)
                    list(name = n, time = private$saved[[n]]$time))),
                pipelines = unname(lapply(names(private$pipelines), function(pl) list(
                    id = pl, label = private$pipelines[[pl]]$label,
                    auto = isTRUE(private$pipelines[[pl]]$auto),
                    removable = !identical(pl, "preprocess"),
                    steps = as.list(private$pipelines[[pl]]$steps),
                    history = unname(lapply(rev(private$runs[[pl]]), function(r) list(
                        run = r$n, time = r$time, label = r$label, params = as.list(r$params),
                        current = private$is_current(pl, r))))))),
                catalog = unname(lapply(private$catalog_, function(e) list(
                    id = e$id, label = e$label, brief = e$brief %||% "",
                    description = e$description %||% "", inputs = as.list(e$inputs),
                    outputs = as.list(e$outputs),
                    included = e$id %in% names(private$pipelines),
                    steps = unname(lapply(names(e$steps), function(s)
                        private$step_schema(s, e$steps[[s]],
                            private$values[[s]] %||%
                                private$default_values(e$steps[s])[[s]])))))),
                steps = unname(lapply(names(private$steps), function(s)
                    private$step_schema(s, private$steps[[s]], private$values[[s]])))
            )
        },

        step_schema = function(s, st, vals) {
            par_schema <- function(par) {
                if (identical(par$type, "column")) return(private$column_schema(s, par))
                if (identical(par$type, "values")) return(private$values_schema(s, par))
                if (identical(par$type, "spatial_network"))
                    return(private$network_schema(s, par))
                range <- identical(par$type, "range")
                list(id = par$id, label = par$label, type = par$type,
                    value = vals[[par$id]], min = par$min,
                    max = if (range) private$max_pcs() else par$max,
                    integer = isTRUE(par$integer),
                    slider = if (range) utils::modifyList(par$slider,
                        list(max = private$max_pcs())) else par$slider,
                    auto = isTRUE(par$auto), placeholder = par$placeholder,
                    view = isTRUE(par$view),
                    help = par$help %||% "", help_src = par$help_src,
                    show_if = if (length(par$show_if)) lapply(par$show_if, as.list),
                    advanced = isTRUE(par$advanced),
                    default = .default_values(list(x = list(params = list(par))),
                        private$disk)$x[[par$id]],
                    choices = lapply(.offered(par$choices, private$disk), function(c)
                        list(value = c$value, label = c$label)))
            }
            list(id = s, label = st$label, fun = st$fun,
                input = if (!is.null(private$steps[[s]])) private$input_of(s) else st$input,
                pipeline = st$pipeline, params = lapply(st$params, par_schema))
        },

        column_schema = function(s, par) {
            cols <- private$group_columns()
            lab <- vapply(cols, function(k) {
                col <- sub("^(analysis|object):", "", k)
                if (startsWith(k, "analysis:")) paste0(col, " (", private$column_source(col), ")")
                else col
            }, "")
            list(id = par$id, label = par$label, type = "choice", help = par$help %||% "",
                advanced = isTRUE(par$advanced), default = "",
                value = private$resolve_column(s),
                choices = unname(Map(function(v, l) list(value = v, label = l),
                    cols, lab)))
        },

        # The menus whose entries depend on other parameters, as one string
        menus_sig = function() paste(unlist(lapply(names(private$steps), function(s)
            lapply(private$steps[[s]]$params, function(q)
                if (q$type %in% .dynamic_types) jsonlite::toJSON(
                    private$step_schema(s, list(params = list(q)), private$values[[s]])$params,
                    auto_unbox = TRUE)))), collapse = "|"),

        # Whether step `s` reads the Normalize step's result
        reads_normalize = function(s) {
            a <- s
            while (!is.null(a)) {
                if (identical(a, "normalize")) return(TRUE)
                a <- if (!is.null(private$steps[[a]])) private$input_of(a)
            }
            FALSE
        },

        # Expression names step `s` may read: the Normalize step's (when `s`
        # reads it) and the loaded object's
        values_choices = function(s) {
            pre <- if (private$reads_normalize(s)) c("normalized",
                if (identical(private$values$normalize$scale, "TRUE")) "scaled")
            list(names = unique(c(pre, private$obj_values)), pre = pre)
        },

        resolve_values = function(s, par) {
            v <- private$values[[s]][[par$id]] %||% ""
            if (nzchar(v)) return(v)
            ch <- private$values_choices(s)$names
            hit <- intersect(par$prefer %||% "normalized", ch)
            if (length(hit)) hit[[1L]] else if (length(ch)) ch[[1L]] else "normalized"
        },

        # The step that makes the spatial network step `s` uses, or NULL
        network_dep = function(s) {
            net <- private$values[[s]]$network
            if (!is.character(net) || identical(net, "new") || net %in% private$obj_networks)
                return(NULL)
            src <- Find(function(x) identical(x$name, net), private$session_networks(s))
            if (!is.null(src)) src$step
        },

        # New spatial networks of the steps besides `s`: name, step, label
        session_networks = function(s = NULL) {
            out <- list()
            for (t in setdiff(names(private$steps), s)) {
                st <- private$steps[[t]]
                if (!any(vapply(st$params, function(q) identical(q$type, "spatial_network"), NA)))
                    next
                if (!identical(private$values[[t]]$network %||% "new", "new")) next
                nm <- .network_of(private$r_values(t, up = FALSE))
                pl <- private$pipelines[[st$pipeline]]$label %||% st$pipeline
                out[[length(out) + 1L]] <- list(name = nm, step = t,
                    label = paste0(nm, " (", pl, ")"))
            }
            out
        },

        network_schema = function(s, par) {
            v <- private$values[[s]][[par$id]] %||% "new"
            obj <- private$obj_networks
            ses <- Filter(function(x) !x$name %in% obj, private$session_networks(s))
            ch <- c(list(list(value = "new", label = "new")),
                lapply(obj, function(n) list(value = n, label = paste0(n, " (loaded object)"))),
                lapply(ses, function(x) list(value = x$name, label = x$label)))
            if (!v %in% vapply(ch, `[[`, "", "value"))
                ch <- c(ch, list(list(value = v, label = paste0(v, " (not found)"))))
            list(id = par$id, label = par$label, type = "choice", help = par$help %||% "",
                help_src = par$help_src, advanced = isTRUE(par$advanced),
                default = .preferred_network(obj) %||% "new", value = v, choices = ch)
        },

        values_schema = function(s, par) {
            ch <- private$values_choices(s)
            v <- private$resolve_values(s, par)
            nm <- unique(c(ch$names, v))
            lab <- ifelse(nm %in% ch$pre, paste0(nm, " (Preprocessing)"), nm)
            list(id = par$id, label = par$label, type = "choice", help = par$help %||% "",
                help_src = par$help_src, advanced = isTRUE(par$advanced), default = "",
                value = v, choices = unname(Map(function(v, l) list(value = v, label = l),
                    nm, lab)))
        },

        send_schema = function() {
            if (private$viewer$connected())
                private$viewer$send("analysis_schema", private$schema())
        },

        set_color = function(column) {
            private$color <- column
            if (!identical(private$pair$column, column)) private$pair <- NULL
            if (private$viewer$connected())
                private$viewer$send("analysis_color", list(column = column))
        },

        send_status = function() {
            r <- private$running
            if (!is.null(r$key) && identical(self$status[[r$step]]$status, "running"))
                self$status[[r$step]]$elapsed <- as.numeric(difftime(Sys.time(), r$t0,
                    units = "secs"))
            if (private$viewer$connected())
                private$viewer$send("analysis_status", list(steps = self$status))
        },

        markers_msg = function() {
            obj <- function(x) if (length(x)) x else structure(list(), names = character())
            list(markers = private$markers, labels = obj(private$cluster_labels),
                inherited = obj(private$inherited), suggested = obj(private$suggested),
                suggestions = private$suggestions,
                columns = list(cluster = private$result_names()$leiden, type = private$result_names()$labels))
        },

        send_markers = function() {
            if (!is.null(private$markers) && private$viewer$connected())
                private$viewer$send("analysis_markers", private$markers_msg())
        }
    )
)

# ── Helpers ──────────────────────────────────────────────────────────────────

# A short key for a set of cell IDs
.ids_key <- function(ids) {
    if (!length(ids)) return("")
    f <- tempfile()
    on.exit(unlink(f))
    writeLines(sort(ids), f)
    unname(tools::md5sum(f))
}

# Marker genes as a named list, cell type -> unique genes
.parse_markers <- function(x) {
    if (is.null(x)) return(list())
    if (is.character(x) && length(x) == 1L && is.null(names(x))) {
        if (!file.exists(x))
            stop("[LensAnalysis] no marker file '", x, "'", call. = FALSE)
        x <- utils::read.csv(x, stringsAsFactors = FALSE, check.names = FALSE)
    }
    if (is.data.frame(x)) {
        if (ncol(x) < 2L)
            stop("[LensAnalysis] a marker table needs a cell type column and a gene column",
                call. = FALSE)
        x <- split(as.character(x[[2L]]), as.character(x[[1L]]))
    }
    if (!is.list(x) || is.null(names(x)) || any(!nzchar(names(x))))
        stop("[LensAnalysis] `cell_markers` must be a list named by cell type",
            call. = FALSE)
    x <- lapply(x, function(g) unique(trimws(as.character(unlist(g)))))
    x <- lapply(x, function(g) g[!is.na(g) & nzchar(g)])
    x[lengths(x) > 0L]
}

# Character and factor columns of `m` with 2 to 200 values, besides cell_ID
# and qc_pass
.label_columns <- function(m, max_levels = 200L) {
    k <- setdiff(names(m), c("cell_ID", "qc_pass"))
    k[vapply(k, function(x) {
        v <- m[[x]]
        if (!is.character(v) && !is.factor(v)) return(FALSE)
        n <- length(unique(v[!is.na(v)]))
        n >= 2L && n <= max_levels
    }, NA)]
}

# The spatial network a network step uses by default: the first of
# Delaunay_network, kNN_network and spatial_network in `nets`, else the first
# of `nets`; NULL when `nets` is empty
.preferred_network <- function(nets) {
    nets <- as.character(nets)
    if (!length(nets)) return(NULL)
    hit <- intersect(c("Delaunay_network", "kNN_network", "spatial_network"), nets)
    if (length(hit)) hit[[1L]] else nets[[1L]]
}

# Parameter types whose menus LensAnalysis fills
.dynamic_types <- c("values", "spatial_network")

.offered <- function(choices, disk) Filter(function(c) !disk || isTRUE(c$disk), choices)

.default_values <- function(steps, disk) {
    lapply(steps, function(st) {
        v <- list()
        for (par in st$params) {
            if (!identical(par$type, "choice")) { v[[par$id]] <- par$default; next }
            ch <- .offered(par$choices, disk)
            keys <- vapply(ch, `[[`, "", "value")
            v[[par$id]] <- if (par$default %in% keys) par$default else keys[[1L]]
        }
        v
    })
}

.value_key <- function(x) {
    if (is.null(x)) return("auto")
    if (is.character(x) && length(x) == 1L) return(x)
    if (is.numeric(x) && length(x) > 1L && all(x == seq_along(x)))
        return(paste0("1:", length(x)))
    paste(deparse(x), collapse = "")
}

.step_code <- function(s, p, up, labels, region = character()) {
    arg <- function(v) {
        if (is.integer(v) && length(v) == 1L) v <- as.numeric(v)
        paste(deparse(v), collapse = "")
    }
    args <- function(lst) paste(vapply(names(lst), function(k)
        paste0(k, " = ", arg(lst[[k]])), ""), collapse = ", ")
    switch(s,
        region = if (length(region)) "g <- subsetGiotto(g, cell_ids = viewer$analysis()$region())" else "",
        filter = paste0("g <- filterGiotto(g, ", args(p), ")"),
        ""
    )
}

# Columns of a cell metadata table that hold 2 to 200 cell types, as
# character; NULL when there are none
.categorical_columns <- function(m, max_levels = 200L) {
    if (is.null(m) || !nrow(m) || !"cell_ID" %in% names(m)) return(NULL)
    out <- list(cell_ID = as.character(m$cell_ID))
    for (k in setdiff(names(m), "cell_ID")) {
        x <- m[[k]]
        if (is.numeric(x)) {
            if (any(x[!is.na(x)] != round(x[!is.na(x)]))) next
        } else if (!is.character(x) && !is.factor(x) && !is.logical(x)) next
        x <- as.character(x)
        n <- length(unique(x[!is.na(x)]))
        if (n >= 2L && n <= max_levels) out[[k]] <- x
    }
    if (length(out) < 2L) return(NULL)
    as.data.frame(out, stringsAsFactors = FALSE, check.names = FALSE)
}

.qc_hist_spec <- function(d, field, title, threshold) {
    d <- d[c(field, intersect(names(d), c("qc_pass", "kept")))]
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = title, width = "container", height = "container",
        data = list(values = d),
        layer = list(
            list(mark = list(type = "bar", tooltip = TRUE),
                encoding = list(
                    x = list(field = field, type = "quantitative", bin = list(maxbins = 60),
                        title = title),
                    y = list(aggregate = "count", type = "quantitative", title = "count"))),
            list(mark = list(type = "rule", color = "#f87171", strokeWidth = 2),
                data = list(values = list(list(t = threshold))),
                encoding = list(x = list(field = "t", type = "quantitative")))
        )
    )
}

.hvf_spec <- function(d) {
    y <- if ("cov" %in% names(d)) "cov" else "var"
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "highly variable features", width = "container", height = "container",
        data = list(values = d),
        mark = list(type = "point", filled = TRUE, size = 12, tooltip = TRUE),
        encoding = list(
            x = list(field = "mean_expr", type = "quantitative", title = "mean expression"),
            y = list(field = y, type = "quantitative", title = y),
            color = list(field = "hvf", type = "nominal",
                scale = list(domain = list("yes", "no"), range = list("#f59e0b", "#4b5563")))
        )
    )
}

.elbow_spec <- function(d) {
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "variance explained", width = "container", height = "container",
        data = list(values = d),
        mark = list(type = "bar", tooltip = TRUE),
        encoding = list(
            x = list(field = "PC", type = "ordinal", title = "PC"),
            y = list(field = "variance", type = "quantitative", title = "fraction of variance",
                axis = list(format = ".1%")))
    )
}

# log2 enrichment for each pair of cell types, both ways round, in `order`
.proximity_spec <- function(d, order) {
    flip <- d[d$type_a != d$type_b, , drop = FALSE]
    flip[c("type_a", "type_b")] <- flip[c("type_b", "type_a")]
    d <- rbind(d, flip)
    lim <- max(abs(d$enrichm[is.finite(d$enrichm)]), 0.1)
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "log2 enrichment of neighbors", width = "container", height = "container",
        data = list(values = d),
        params = list(list(name = "pick",
            select = list(type = "point", fields = list("type_a", "type_b"), on = "click",
                clear = "dblclick"))),
        mark = list(type = "rect", tooltip = TRUE, cursor = "pointer"),
        encoding = list(
            x = list(field = "type_a", type = "nominal", sort = as.list(order), title = NULL),
            y = list(field = "type_b", type = "nominal", sort = as.list(order), title = NULL),
            color = list(field = "enrichm", type = "quantitative", title = "log2 enrichment",
                scale = list(scheme = "redblue", reverse = TRUE, domain = list(-lim, lim))),
            tooltip = list(
                list(field = "pair", type = "nominal"),
                list(field = "enrichm", type = "quantitative", format = ".2f",
                    title = "log2 enrichment"),
                list(field = "original", type = "quantitative", title = "links"),
                list(field = "simulations", type = "quantitative", format = ".1f",
                    title = "links, random"),
                list(field = "p_adj_higher", type = "quantitative", format = ".3g",
                    title = "p.adj higher"),
                list(field = "p_adj_lower", type = "quantitative", format = ".3g",
                    title = "p.adj lower")))
    )
}

# "label: value" for each parameter of `steps`, for the History menu
.param_lines <- function(steps, values) {
    out <- character()
    for (s in names(steps)) for (par in steps[[s]]$params) {
        v <- values[[s]][[par$id]]
        if (is.null(v)) next
        if (identical(par$type, "choice")) {
            ch <- Find(function(c) identical(c$value, v), par$choices)
            if (!is.null(ch)) v <- ch$label
        }
        if (identical(par$type, "column")) v <- sub("^(analysis|object):", "", v)
        out <- c(out, paste0(steps[[s]]$label, " / ", par$label, ": ",
            if (nzchar(v)) v else "default"))
    }
    out
}
