# ── launch_lens_analysis() ───────────────────────────────────────────────────

#' Launch GiottoLens in analysis mode
#'
#' Opens the viewer with an Analysis panel that runs the first steps of a
#' Giotto analysis on `x`: QC filter ([Giotto::filterGiotto()]), normalization,
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
#' categorical cell metadata column of `x` or of the Preprocessing tab, and
#' expression from the Preprocessing tab or `x`. The steps of added analyses
#' run only when asked: the Run button of a step runs it and the stale steps
#' above it, Run all runs every stale step of the analysis, and `$run()` does
#' the same from R. A change marks the step and those below it stale and drops
#' their pending runs. Each finished run of an analysis is kept for the session
#' and listed under History, which brings back its parameters and results.
#' Clicking a gene in a result table colors the cells by its expression.
#'
#' The steps run in a background R session that holds a copy of `x`, so the
#' viewer stays responsive; a change made while a step runs cancels that step
#' when its result would be stale. Stores the steps create are written to a
#' temporary GiottoDisk source; the object's own source is only read.
#'
#' @param x A giotto object with polygons (or spatial locations) for
#'   `spat_unit` and raw expression for `feat_type`.
#' @param params Starting parameter values: a list by step of lists by
#'   parameter, e.g. `list(filter = list(min_det_feats_per_cell = 20))`. Menu
#'   parameters take one of their choices; number parameters (thresholds,
#'   PCs, resolution, ...) any number in their range, typed in the viewer the
#'   same way. Parameters left out take Giotto's
#'   defaults; on GiottoDisk expression, z-score scaling and the normalization
#'   methods other than `"standard"` are not offered.
#' @param cell_markers Marker genes for the Automatic types step: a named list
#'   (cell type -> genes), a data.frame with the cell type in its first column
#'   and a gene in its second, or the path of such a CSV file. `NULL` leaves
#'   the step blocked until [LensAnalysis] `$cell_markers()` sets a list.
#' @param settings A JSON file written by [LensAnalysis] `$write_settings()`;
#'   its saved settings are listed in the viewer, ready to restore.
#' @param threads Threads for UMAP and data.table in the background session.
#' @param analyses Ids of the analyses to include besides Preprocessing; see
#'   [LensAnalysis] `$catalog()`.
#' @param spat_unit,feat_type Spatial unit and feature type to analyze.
#' @param open Open the viewer, see [launch_lens()].
#' @param ... Passed to [launch_lens()].
#' @return The [LensViewer]. Its `analysis` field is a [LensAnalysis] with
#'   `params()`, `set()`, `run()`, `add()`, `remove()`, `history()`,
#'   `restore_run()`, `labels()`, `cell_markers()`, `save_settings()`,
#'   `restore_settings()`, `code()`, `gobject()` and `wait()`.
#' @export
launch_lens_analysis <- function(x, params = NULL, cell_markers = NULL, settings = NULL,
                                 threads = 4L,
                                 analyses = character(),
                                 spat_unit = "cell", feat_type = "rna",
                                 open = TRUE, ...) {
    if (!inherits(x, "giotto"))
        stop("[launch_lens_analysis] `x` must be a giotto object", call. = FALSE)
    if (!requireNamespace("callr", quietly = TRUE))
        stop("[launch_lens_analysis] needs the callr package", call. = FALSE)
    viewer <- launch_lens(x, spat_unit = spat_unit, feat_type = feat_type,
        open = FALSE, ...)
    viewer$analysis <- LensAnalysis$new(viewer, x, params = params,
        cell_markers = cell_markers, threads = threads, analyses = analyses,
        spat_unit = spat_unit, feat_type = feat_type)
    if (!is.null(settings)) viewer$analysis$read_settings(settings)
    if (open) .open_viewer(viewer$url)
    invisible(viewer)
}

# ── Worker side (runs in the callr session; self-contained) ─────────────────

.aw_init <- function(libpaths, file, scratch, threads) {
    .libPaths(libpaths)
    options(giotto.check_core = FALSE, giotto.cores = threads,
        tilework.warn_sequential = FALSE)
    suppressPackageStartupMessages({
        library(Giotto)
        if (requireNamespace("GiottoDisk", quietly = TRUE)) library(GiottoDisk)
    })
    data.table::setDTthreads(threads)
    g <- readRDS(file)
    raw <- GiottoClass::getExpression(g, values = "raw", output = "exprObj")[]
    disk <- inherits(raw, "parquetExprStore")
    if (inherits(g@source, "gDirSource")) {
        dir.create(scratch, recursive = TRUE, showWarnings = FALSE)
        src <- GiottoDisk::sourceCreate(scratch)
        g@source <- src
        GiottoDisk::setArtifactDumpDir(src, verbose = FALSE)
    }
    w <- new.env()
    w$base  <- g
    w$cache <- list()
    assign(".lens_w", w, envir = globalenv())
    assign(".lens_values", function(p)
        if (isTRUE(p$up$normalize$scale)) "scaled" else "normalized", envir = globalenv())
    assign(".lens_threads", function() threads, envir = globalenv())
    list(disk = disk, n_cells = ncol(raw), n_feats = nrow(raw))
}

.aw_step <- function(run, result, key, parent, p, keep) {
    w <- get(".lens_w", envir = globalenv())
    before <- if (is.null(parent)) w$base else w$cache[[parent]]
    if (is.null(before)) stop("lens_missing_input")
    t0 <- proc.time()[["elapsed"]]
    g <- w$cache[[key]]
    if (is.null(g)) g <- run(before, p)
    w$cache[[key]] <- g
    w$cache <- w$cache[intersect(names(w$cache), keep)]
    res <- result(g, p, before)
    list(result = res, secs = proc.time()[["elapsed"]] - t0)
}

.aw_gobject <- function(key, umap_key, file) {
    w <- get(".lens_w", envir = globalenv())
    g <- w$cache[[key]]
    if (is.null(g)) stop("the last step has no result yet")
    u <- if (!is.null(umap_key)) w$cache[[umap_key]]
    if (!is.null(u)) {
        d <- GiottoClass::getDimReduction(u, reduction_method = "umap", name = "umap",
            output = "dimObj")
        keep <- intersect(GiottoClass::spatIDs(g), rownames(d[]))
        d[] <- d[][keep, , drop = FALSE]
        g <- GiottoClass::setGiotto(g, d, verbose = FALSE)
    }
    saveRDS(g, file)
    file
}

# Expression of one feature: normalized values from the first object of
# steps `keys` that has them, else raw values of the first object (the loaded
# object when no step has a result)
.aw_feature <- function(keys, feat) {
    w <- get(".lens_w", envir = globalenv())
    objs <- c(Filter(Negate(is.null), lapply(keys, function(k) w$cache[[k]])), list(w$base))
    norm <- Filter(function(o) "normalized" %in%
        as.data.frame(GiottoClass::list_expression(o))$name, objs)
    g <- if (length(norm)) norm[[1L]] else objs[[1L]]
    vals <- if (length(norm)) "normalized" else "raw"
    if (!feat %in% GiottoClass::featIDs(g)) stop("'", feat, "' is not a feature of the object")
    d <- as.data.frame(suppressMessages(GiottoClass::spatValues(g, feats = feat,
        expression_values = vals)))
    list(cell_ID = as.character(d$cell_ID), value = as.numeric(d[[feat]]), values = vals)
}

# ── LensAnalysis ─────────────────────────────────────────────────────────────

#' Analysis state behind a viewer launched with [launch_lens_analysis()]
#'
#' Holds the parameter values, runs stale steps in a background R session
#' and pushes their results to the viewer. Use it through `viewer$analysis`.
#'
#' @export
LensAnalysis <- R6::R6Class("LensAnalysis",
    public = list(
        #' @field status Per step: `status` (`"stale"`, `"running"`, `"done"`,
        #'   `"error"`, `"blocked"`), `secs`, `summary`, `message`
        status = NULL,

        #' @description Start the background session. Use
        #'   [launch_lens_analysis()] instead.
        #' @param viewer The [LensViewer]
        #' @param x The giotto object
        #' @param params Starting values, see [launch_lens_analysis()]
        #' @param cell_markers Marker genes, see [launch_lens_analysis()]
        #' @param threads Threads in the background session
        #' @param analyses Analyses besides Preprocessing, see [launch_lens_analysis()]
        #' @param spat_unit,feat_type Spatial unit and feature type
        initialize = function(viewer, x, params = NULL, cell_markers = NULL, threads = 4L,
                              analyses = character(),
                              spat_unit = "cell", feat_type = "rna") {
            private$viewer <- viewer
            private$catalog_ <- .analysis_catalog()
            analyses <- as.character(unlist(analyses))
            bad <- setdiff(analyses, names(private$catalog_))
            if (length(bad))
                stop("[LensAnalysis] no analysis ", paste0("'", bad, "'", collapse = ", "),
                    "; analyses: ", paste(names(private$catalog_), collapse = ", "),
                    call. = FALSE)
            private$dir    <- file.path(tempdir(), "giottolens-analysis", .rand_id(8L))
            dir.create(private$dir, recursive = TRUE, showWarnings = FALSE)
            raw <- GiottoClass::getExpression(x, values = "raw", spat_unit = spat_unit,
                feat_type = feat_type, output = "exprObj")[]
            private$disk <- inherits(raw, "parquetExprStore")
            for (id in unique(c("preprocess", analyses))) private$include(id)
            private$markers_in <- .parse_markers(cell_markers)
            private$meta <- data.frame(cell_ID = as.character(GiottoClass::spatIDs(x,
                spat_unit = spat_unit)))
            private$obj_meta <- .categorical_columns(as.data.frame(GiottoClass::pDataDT(x,
                spat_unit = spat_unit, feat_type = feat_type)))
            if (length(params)) for (s in names(params)) for (k in names(params[[s]]))
                private$check_set(s, k, params[[s]][[k]])
            private$update_keys()
            f <- file.path(private$dir, "input.rds")
            saveRDS(x, f)
            private$worker <- callr::r_session$new(wait = TRUE)
            private$worker$call(.aw_init, list(.libPaths(), f,
                file.path(private$dir, "source"), as.integer(threads)))
            private$running <- list(step = ".init")
            private$tick()
        },

        #' @description Parameter values as R values, by step
        params = function() {
            lapply(stats::setNames(names(private$steps), names(private$steps)), function(s)
                private$r_values(s))
        },

        #' @description Set parameters; affected steps of the Preprocessing
        #'   tab rerun, those of the other tabs wait for `run()`
        #' @param step Step id (`names(viewer$analysis$params())`)
        #' @param ... `parameter = value` pairs: a menu choice, or for a number
        #'   parameter any number in its range
        set = function(step, ...) {
            vals <- list(...)
            for (k in names(vals)) private$check_set(step, k, vals[[k]])
            private$changed()
            if (private$viewer$connected())
                private$viewer$send("analysis_schema", private$schema())
            invisible(self)
        },

        #' @description Run the stale steps of an analysis, or one step and the
        #'   stale steps above it
        #' @param pipeline Analysis id (`names(viewer$analysis$analyses())`);
        #'   ignored when `step` is given
        #' @param step Step id; `NULL` for every step of the analysis
        run = function(pipeline = "interactions", step = NULL) {
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
        #'   [launch_lens_analysis()]
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
        #' @param x Marker genes, see [launch_lens_analysis()]; `NULL` to get
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
            f <- file.path(private$dir, "result.rds")
            private$worker$run(.aw_gobject, list(private$keys[[last]],
                private$keys[["umap"]], f))
            readRDS(f)
        },

        #' @description R code that reproduces the current parameters
        #' @param pipeline Analysis id
        code = function(pipeline = "preprocess") {
            private$check_pipeline(pipeline)
            steps <- private$pipelines[[pipeline]]$steps
            out <- character()
            for (s in setdiff(steps, if (!length(private$markers_in)) "auto_type")) {
                st <- private$steps[[s]]
                out <- c(out, if (is.function(st$code))
                    st$code(private$r_values(s, up = FALSE), private$r_values(s)$up)
                else .step_code(s, private$r_values(s, up = FALSE),
                    private$r_values(s)$up, unlist(private$cluster_labels), private$region_ids))
            }
            paste(out[nzchar(out)], collapse = "\n")
        },

        #' @description Stop the running step and drop pending runs; stale
        #'   steps wait for the next change or `run()`
        cancel = function() {
            private$requested <- list()
            for (s in names(private$steps))
                if (identical(self$status[[s]]$status, "queued"))
                    self$status[[s]] <- list(status = "stale")
            private$interrupt()
            private$send_status()
            invisible(self)
        },

        #' @description Stop the background session
        close = function() {
            if (!is.null(private$worker)) {
                try(private$worker$close(), silent = TRUE)
                private$worker <- NULL
            }
            unlink(private$dir, recursive = TRUE)
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
                    private$changed()
                },
                analysis_labels = {
                    private$set_labels(as.list(unlist(data$labels %||% list())))
                    private$changed()
                },
                analysis_cancel = self$cancel(),
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
        on_ready = function(ws) {
            ws$send(.encode_ws_message("analysis_schema", private$schema()))
            ws$send(.encode_ws_message("analysis_status", list(steps = self$status)))
            if (!is.null(private$markers))
                ws$send(.encode_ws_message("analysis_markers", private$markers_msg()))
            if (!is.null(private$color))
                ws$send(.encode_ws_message("analysis_color", list(column = private$color)))
            ws$send(.encode_ws_message("analysis_tables", private$tables_msg()))
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
        viewer = NULL, steps = NULL, dir = NULL, disk = FALSE, values = NULL,
        keys = NULL, done = list(), worker = NULL, running = NULL,
        cancelled = FALSE, cluster_labels = list(), meta = NULL, markers = NULL,
        colored = FALSE, color = NULL, timer = NULL, recent = character(),
        cols = list(), debounce = NULL, info = NULL, meta_timer = NULL,
        label_store = list(), inherited = list(), snap = NULL, n_pcs = NULL, saved = list(),
        region_ids = character(),
        markers_in = list(), suggested = list(), suggestions = NULL,
        pipelines = list(), requested = list(), obj_meta = NULL, group_cache = list(),
        group_cols = NULL, catalog_ = NULL, tables = list(), results = list(), runs = list(),
        run_seq = 0L, active = FALSE, panels_of = list(), feature = NULL, feature_col = NULL,

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
            defaults <- .default_values(ent$steps, private$disk)
            for (s in names(ent$steps)) {
                private$steps[[s]] <- ent$steps[[s]]
                if (is.null(private$values[[s]])) private$values[[s]] <- defaults[[s]]
                self$status[[s]] <- list(status = "stale")
            }
            if (!is.null(private$meta)) private$update_keys()
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
        want_feature = function(step, feat) {
            if (!nzchar(feat)) stop("no feature", call. = FALSE)
            private$feature <- list(step = step, feat = feat)
            private$tick()
        },

        tables_msg = function() list(tables = if (length(private$tables)) private$tables
            else structure(list(), names = character())),

        send_tables = function() {
            if (private$viewer$connected())
                private$viewer$send("analysis_tables", private$tables_msg())
        },

        interrupt = function() {
            if (!is.null(private$running$key)) {
                private$worker$interrupt()
                private$cancelled <- TRUE
            }
        },

        auto = function(s) isTRUE(private$pipelines[[private$steps[[s]]$pipeline]]$auto),

        # Whether a stale step may run now: always in an auto tab, else when
        # run() asked for its current parameters
        wanted = function(s) private$auto(s) ||
            identical(private$requested[[s]], private$keys[[s]]),

        idle_status = function(s)
            if (!private$auto(s) && private$wanted(s)) "queued" else "stale",

        # Cell type columns as menu keys: "analysis:<col>" for columns of the
        # Preprocessing tab, "object:<col>" for those of the loaded object
        group_columns = function() {
            ac <- intersect(c("cell_type", "leiden_clus", "cell_type_auto"), names(private$meta))
            ac <- ac[vapply(ac, function(k) any(!is.na(private$meta[[k]])), NA)]
            c(if (length(ac)) paste0("analysis:", ac),
              if (length(private$obj_meta)) paste0("object:", setdiff(names(private$obj_meta),
                  "cell_ID")))
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
            pick <- intersect(c(paste0(src, "cell_type"), paste0(src, "leiden_clus")), cols)
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
                p[par$id] <- list(.param_r(par, key))
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
            keys <- list()
            for (s in names(private$steps)) {
                parent <- private$input_of(s)
                own <- private$values[[s]]
                vp <- vapply(private$steps[[s]]$params, function(q) isTRUE(q$view), NA)
                if (any(vp)) own[vapply(private$steps[[s]]$params[vp], `[[`, "", "id")] <- NULL
                if (s == "labels") own$labels <- private$cluster_labels
                if (s == "auto_type" || isTRUE(private$steps[[s]]$markers))
                    own$cell_markers <- private$markers_in
                if (s == "region") own$cells <- .ids_key(private$region_ids)
                if (identical(private$steps[[s]]$kind, "groups")) {
                    own$column <- private$resolve_column(s)
                    own$data <- private$group_sig(s)
                    own$cells <- .ids_key(private$region_ids)
                }
                keys[[s]] <- paste0(s, "{", jsonlite::toJSON(own, auto_unbox = TRUE),
                    "}<", if (!is.null(parent)) keys[[parent]])
            }
            private$keys <- keys
        },

        stale = function(s) !identical(private$done[[s]], private$keys[[s]]),
        busy  = function() !is.null(private$running) || !is.null(private$meta_timer) ||
            !is.null(private$feature) ||
            any(vapply(names(private$steps), function(s) private$stale(s) &&
                private$wanted(s) &&
                !identical(self$status[[s]]$status, "error") &&
                !identical(self$status[[s]]$status, "blocked"), NA)),

        changed = function() {
            old_leiden <- private$keys[["leiden"]]
            private$update_keys()
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
                if (s == "auto_type" && !length(private$markers_in)) {
                    self$status[[s]] <- list(status = "blocked", message = paste(
                        "no marker list: launch_lens_analysis(g, cell_markers =) or",
                        "viewer$analysis$cell_markers()"))
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
            self$status[[s]] <- list(status = "running")
            private$send_status()
            p <- private$r_values(s)
            if (identical(st$kind, "groups")) p$groups <- private$group_data(s)
            private$worker$call(.aw_step, list(run, result, private$keys[[s]],
                if (!is.null(parent)) private$keys[[parent]], p,
                unique(c(unname(unlist(private$keys)), private$recent))))
        },

        tick = function() {
            if (is.function(private$timer)) private$timer()
            private$timer <- NULL
            if (is.null(private$worker)) return(invisible())
            r <- private$running
            if (!is.null(r)) {
                if (private$worker$poll_process(0) != "ready") {
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
                        warning("[LensAnalysis] the background session failed to start: ",
                            conditionMessage(out$error), call. = FALSE)
                        return(invisible())
                    }
                    private$info <- out$result
                } else if (identical(r$step, ".feature")) {
                    private$show_feature(r, out)
                } else private$finish(r, out)
            }
            if (is.null(private$running) && !is.null(private$feature)) {
                f <- private$feature
                private$feature <- NULL
                cand <- intersect(c(f$step, "labels", "normalize"), names(private$steps))
                keys <- unname(unlist(private$keys[cand[!vapply(cand, private$stale, NA)]]))
                private$running <- list(step = ".feature", feat = f$feat)
                private$worker$call(.aw_feature, list(as.list(keys), f$feat))
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

        show_feature = function(r, out) {
            if (!is.null(out$error)) {
                msg <- conditionMessage(out$error$parent %||% out$error)
                private$viewer$send("analysis_feature", list(feat = r$feat, error = msg))
                return(invisible())
            }
            d <- out$result
            col <- paste0("expr_", r$feat)
            m <- data.frame(cell_ID = d$cell_ID)
            m[[col]] <- d$value
            if (!is.null(private$feature_col) && !identical(private$feature_col, col) &&
                private$feature_col %in% names(private$meta))
                private$meta[[private$feature_col]] <- NULL
            private$feature_col <- col
            private$merge_meta(m, ".feature")
            private$set_color(col)
            private$viewer$send("analysis_feature", list(feat = r$feat, column = col,
                values = d$values))
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
                    if (is.null(private$label_store[[private$keys[["leiden"]]]]))
                        private$carry_labels(res$meta)
                    private$snap <- list(key = private$keys[["leiden"]], cl = res$meta)
                    if (!private$colored) {
                        private$colored <- TRUE
                        private$set_color("leiden_clus")
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
            private$push_meta()
            private$refresh_groups()
        },

        # One metadata push for results that arrive close together
        push_meta = function() {
            if (!is.null(private$meta_timer)) return(invisible())
            private$meta_timer <- later::later(function() {
                private$meta_timer <- NULL
                if (!is.null(private$meta) && ncol(private$meta) > 1L)
                    suppressMessages(private$viewer$push_metadata(private$meta))
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
                            private$values[[s]] %||% .default_values(e$steps[s],
                                private$disk)[[s]])))))),
                steps = unname(lapply(names(private$steps), function(s)
                    private$step_schema(s, private$steps[[s]], private$values[[s]])))
            )
        },

        step_schema = function(s, st, vals) {
            par_schema <- function(par) {
                if (identical(par$type, "column")) return(private$column_schema(s, par))
                range <- identical(par$type, "range")
                list(id = par$id, label = par$label, type = par$type,
                    value = vals[[par$id]], min = par$min,
                    max = if (range) private$max_pcs() else par$max,
                    integer = isTRUE(par$integer),
                    slider = if (range) utils::modifyList(par$slider,
                        list(max = private$max_pcs())) else par$slider,
                    auto = isTRUE(par$auto), placeholder = par$placeholder,
                    view = isTRUE(par$view),
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
                if (startsWith(k, "analysis:")) paste0(col, " (Preprocessing)") else col
            }, "")
            list(id = par$id, label = par$label, type = "choice",
                value = private$resolve_column(s),
                choices = unname(Map(function(v, l) list(value = v, label = l),
                    cols, lab)))
        },

        send_schema = function() {
            if (private$viewer$connected())
                private$viewer$send("analysis_schema", private$schema())
        },

        set_color = function(column) {
            private$color <- column
            if (private$viewer$connected())
                private$viewer$send("analysis_color", list(column = column))
        },

        send_status = function() {
            if (private$viewer$connected())
                private$viewer$send("analysis_status", list(steps = self$status))
        },

        markers_msg = function() {
            obj <- function(x) if (length(x)) x else structure(list(), names = character())
            list(markers = private$markers, labels = obj(private$cluster_labels),
                inherited = obj(private$inherited), suggested = obj(private$suggested),
                suggestions = private$suggestions)
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
    vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
    switch(s,
        region = if (length(region)) "g <- subsetGiotto(g, cell_ids = viewer$analysis$region())" else "",
        filter = paste0("g <- filterGiotto(g, ", args(p), ")"),
        normalize = paste0("g <- normalizeGiotto(g, norm_methods = ", arg(p$norm_methods),
            ", scalefactor = ", arg(p$scalefactor), ", log_norm = ", arg(p$log_norm),
            ", scale_feats = ", arg(p$scale), ", scale_cells = ", arg(p$scale), ")"),
        hvf = paste0("g <- calculateHVF(g, ", args(p), ")"),
        pca = paste0("g <- runPCA(g, expression_values = ", arg(vals), ", ", args(p), ")"),
        umap = paste0("g <- runUMAP(g, expression_values = ", arg(vals), ", ",
            args(Filter(Negate(is.null), p)), ")"),
        network = paste0("g <- createNearestNetwork(g, expression_values = ", arg(vals),
            ", ", args(p), ")"),
        leiden = paste0("g <- doLeidenCluster(g, nn_network_to_use = ", arg(up$network$type),
            ", network_name = ", arg(paste0(up$network$type, ".pca")), ", ", args(p),
            ", name = \"leiden_clus\")"),
        markers = paste0("markers <- findMarkers_one_vs_all(g, expression_values = ",
            arg(vals), ", cluster_column = \"leiden_clus\", method = ", arg(p$method), ")"),
        auto_type = paste0("sign <- makeSignMatrixPAGE(sign_names = names(cell_markers), ",
            "sign_list = cell_markers)\n",
            if (p$method == "PAGE") paste0("g <- runPAGEEnrich(g, sign_matrix = sign, ",
                "expression_values = ", arg(vals), ", min_overlap_genes = ",
                arg(p$min_overlap_genes), ", name = \"lens_auto\")")
            else paste0("g <- runHyperGeometricEnrich(g, sign_matrix = sign, ",
                "expression_values = ", arg(vals), ", top_percentage = ",
                arg(p$top_percentage), ", name = \"lens_auto\")")),
        labels = if (length(labels)) paste0("g <- annotateGiotto(g, annotation_vector = ",
            arg(labels), ", cluster_column = \"leiden_clus\", name = \"cell_type\")") else ""
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
        mark = list(type = "rect", tooltip = TRUE),
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
