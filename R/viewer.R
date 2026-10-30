# ── launch_lens() ────────────────────────────────────────────────────────────

#' Launch the GiottoLens viewer
#'
#' Starts a combined HTTP + WebSocket server via httpuv and opens the viewer.
#' The viewer bundle and the GiottoDisk stores are served in place; only the
#' manifest and pushed metadata are written, to a per-viewer temp directory.
#' Tile data goes through a Range-aware handler so the viewer reads only the
#' columns it draws.
#'
#' @param x          A giotto object **or** a giottoPoints backed by a
#'   GiottoDisk tile store.
#' @param gpolygons  giottoPolygon backed by a GiottoDisk tile store. Ignored
#'   when `x` is a giotto object.
#' @param feat_type  Feature type key when `x` is a giotto object (default
#'   `"rna"`). `NULL` launches without transcripts.
#' @param spat_unit  Spatial unit key when `x` is a giotto object (default
#'   `"cell"`). `NULL` launches without polygons.
#' @param port       Port for the HTTP + WebSocket server. `NULL` (default)
#'   picks a free one. Launching on the port of a running viewer closes that
#'   viewer first.
#' @param host       Interface to listen on. The default only accepts
#'   connections from this machine; use `"0.0.0.0"` to expose the viewer and
#'   its data to the network.
#' @param url_prefix Base URL the browser uses to reach the server (default
#'   `http://127.0.0.1:{port}`). Set it when the server is behind a proxy or
#'   port forward.
#' @param open       Open the viewer (default `TRUE`): in the IDE's viewer pane
#'   in RStudio (Desktop, Server, Workbench) and Positron, otherwise in the
#'   browser. Set `options(GiottoLens.viewer = "browser")` to always use the
#'   browser.
#' @param transfer   How the browser reads tiles: `"whole"` fetches each tile
#'   file in one request (fastest when the browser and R share a machine),
#'   `"columns"` fetches only the drawn columns with merged Range requests
#'   (fewer bytes, for slow links such as SSH port forwards). `"auto"`
#'   (default) starts with whole tiles on a localhost URL and switches to
#'   columns if tiles arrive slowly.
#' @return A [LensViewer]; call `$close()` to stop the server.
#' @export
launch_lens <- function(
    x          = NULL,
    gpolygons  = NULL,
    feat_type  = "rna",
    spat_unit  = "cell",
    port       = NULL,
    host       = "127.0.0.1",
    url_prefix = NULL,
    open       = TRUE,
    transfer   = c("auto", "whole", "columns")
) {
    transfer <- match.arg(transfer)
    layers <- .resolve_layers(x, gpolygons, feat_type, spat_unit)

    port <- if (is.null(port)) httpuv::randomPort(host = host) else as.integer(port)
    old  <- .lens_registry[[as.character(port)]]
    if (!is.null(old)) {
        message("[launch_lens] closing the viewer already on port ", port)
        old$close()
    }
    url_prefix <- sub("/+$", "", url_prefix %||% paste0("http://127.0.0.1:", port))

    viewer <- LensViewer$new(
        gpoints = layers$gpoints, gpolygons = layers$gpolygons,
        port = port, host = host, url_prefix = url_prefix, transfer = transfer,
        spat_unit = if (inherits(x, "giotto")) spat_unit
    )
    if (open) .open_viewer(viewer$url)
    message("Viewer: ", viewer$url)
    invisible(viewer)
}

#' @rdname launch_lens
#' @param ... Passed to [launch_lens()].
#' @description `serve_lens()` is a deprecated alias for [launch_lens()] kept
#'   for backward compatibility.
#' @export
serve_lens <- function(...) {
    .Deprecated("launch_lens")
    launch_lens(...)
}

# RStudio shows localhost URLs in its viewer pane through its `viewer` option
# (as htmlwidgets does), and RStudio Server / Workbench proxy them there.
# Positron's browseURL() already opens its Viewer pane. Shiny is not involved:
# the pane only needs a URL on this machine.
.ide <- function() {
    if (nzchar(Sys.getenv("POSITRON"))) return("positron")
    if (identical(Sys.getenv("RSTUDIO"), "1"))
        return(if (identical(Sys.getenv("RSTUDIO_PROGRAM_MODE"), "server")) "rstudio-server" else "rstudio")
    "none"
}

.open_viewer <- function(url, ide = .ide(), pane = getOption("viewer")) {
    use_pane <- ide %in% c("rstudio", "rstudio-server") && is.function(pane) &&
        !identical(getOption("GiottoLens.viewer"), "browser")
    if (use_pane) pane(url) else utils::browseURL(url)
    invisible(if (use_pane) "pane" else "browser")
}

# Running viewers by port, so a relaunch on the same port can close the old
# server and package unload can close them all.
.lens_registry <- new.env(parent = emptyenv())

.onUnload <- function(libpath) {
    for (v in as.list(.lens_registry)) try(v$close(), silent = TRUE)
}

.resolve_layers <- function(x, gpolygons, feat_type, spat_unit) {
    if (inherits(x, "giotto")) {
        gpoints   <- .pick_layer(x@feat_info, feat_type, "feat_type")
        gpolygons <- .pick_layer(x@spatial_info, spat_unit, "spat_unit")
    } else {
        gpoints <- x
    }
    if (is.null(gpoints) && is.null(gpolygons))
        stop("[launch_lens] nothing to show: provide points and/or polygons",
            call. = FALSE)
    .check_tile_store(gpoints, "giottoPoints", "points")
    .check_tile_store(gpolygons, "giottoPolygon", "polygons")
    list(gpoints = gpoints, gpolygons = gpolygons)
}

.pick_layer <- function(slot_list, key, arg) {
    if (is.null(key)) return(NULL)
    if (!key %in% names(slot_list)) {
        stop(sprintf("[launch_lens] %s '%s' not found; available: %s (or NULL to skip)",
            arg, key, if (length(slot_list)) paste(names(slot_list), collapse = ", ")
                      else "none"),
            call. = FALSE)
    }
    slot_list[[key]]
}

.check_tile_store <- function(obj, cls, what) {
    if (is.null(obj)) return(invisible())
    if (!inherits(obj, cls))
        stop(sprintf("[launch_lens] %s must be a %s, not %s",
            what, cls, class(obj)[[1L]]), call. = FALSE)
    sv <- obj@spatVector
    if (!all(vapply(c("path", "tiles", "uid"), methods::.hasSlot, logical(1L), object = sv))) {
        stop(sprintf(paste0("[launch_lens] %s are in memory (%s); GiottoLens ",
            "reads GiottoDisk tile stores. Save the object with saveGiotto() ",
            "and load it with loadGiotto() first"), what, class(sv)[[1L]]),
            call. = FALSE)
    }
    invisible()
}


# ── LensViewer ───────────────────────────────────────────────────────────────

#' Viewer server returned by [launch_lens()]
#'
#' Owns the httpuv server for one viewer. WebSocket messages from the browser
#' (selection, annotations) arrive on the main R thread and update the public
#' fields. Several browser tabs may connect; messages to the viewer go to all
#' of them.
#'
#' @export
LensViewer <- R6::R6Class("LensViewer",

    public = list(
        #' @field port        Server port
        port        = NULL,
        #' @field url         Viewer URL. It contains this launch's token: treat
        #'   it like a password while the viewer runs
        url         = NULL,
        #' @field selection   Character vector of selected cell IDs
        selection   = NULL,
        #' @field selection_rules The rules behind the current selection, as
        #'   sent by the viewer (one per source: spatial, scatter, histogram, ...)
        selection_rules = NULL,
        #' @field annotations List of drawn polygons: id, name, type, geojson
        annotations = list(),

        #' @description Start a viewer server. Use [launch_lens()] instead.
        #' @param gpoints,gpolygons Tile-store-backed layers (either may be NULL)
        #' @param port,host Where to listen
        #' @param url_prefix Base URL the browser uses
        #' @param transfer Tile transfer mode, see [launch_lens()]
        #' @param spat_unit Spatial unit the polygons belong to (for `subset()`)
        initialize = function(gpoints, gpolygons, port, host, url_prefix,
                              transfer = "auto", spat_unit = NULL) {
            self$port         <- port
            private$spat_unit <- spat_unit
            private$token     <- .rand_id(24L)
            private$conns     <- new.env(parent = emptyenv())
            private$session   <- file.path(tempdir(), "giottolens",
                paste0(port, "-", .rand_id(8L)))
            dir.create(file.path(private$session, "metadata"),
                recursive = TRUE, showWarnings = FALSE)
            private$cell_ids <- .export_session(gpoints, gpolygons,
                output = file.path(private$session, "manifest.json"), transfer = transfer)
            self$url <- paste0(url_prefix, .lens_root(private$token), "/")
            private$start_server(host, .layer_mounts(gpoints, gpolygons))
            assign(as.character(port), self, envir = .lens_registry)
        },

        #' @description Send a typed message to every connected tab
        #' @param type Message type
        #' @param data Payload (converted with jsonlite)
        send = function(type, data = NULL) {
            if (!self$connected()) {
                warning("[LensViewer] no viewer connected yet", call. = FALSE)
                return(invisible(self))
            }
            private$broadcast(.encode_ws_message(type, data))
            invisible(self)
        },

        #' @description Whether any browser tab is connected
        connected = function() length(private$conns) > 0L,

        #' @description Push cell metadata to the viewer for coloring, the
        #'   tooltip and the stats panels. Works before a browser connects:
        #'   the latest metadata is sent to every tab when it connects.
        #' @param x         A giotto object, or a data.frame / output of
        #'   [prep_meta()] with a `cell_ID` column
        #' @param cols      Columns to include (NULL = all; ignored when x is a
        #'   data.frame). A named list such as `list(leiden_clus = "categorical")`
        #'   also sets each column's type; see [prep_meta()]
        #' @param dimreds   Dimension reduction names to include, e.g. `c("umap","tsne")`
        #' @param dims      Axes to pull from each reduction (default `1:2`)
        #' @param spat_unit Spatial unit key (default `"cell"`)
        #' @param feat_type Feature type key for dim reds (default `"rna"`)
        push_metadata = function(x, cols = NULL, dimreds = NULL, dims = 1:2,
                                 spat_unit = "cell", feat_type = "rna") {
            meta <- if (inherits(x, "giotto")) {
                prep_meta(x, cols = cols, dimreds = dimreds, dims = dims,
                    spat_unit = spat_unit, feat_type = feat_type)
            } else {
                as.data.frame(x)
            }
            out <- .write_metadata(meta, file.path(private$session, "metadata"),
                private$cell_ids)
            msg <- out$msg
            private$meta_table  <- out$table
            private$cached_meta <- msg
            if (self$connected())
                private$broadcast(.encode_ws_message("load_metadata", msg))
            message("[LensViewer] metadata: ", length(msg$columns), " column(s): ",
                paste(vapply(msg$columns, `[[`, "", "name"), collapse = ", "),
                if (!self$connected()) " (sent when the viewer connects)")
            invisible(self)
        },

        #' @description Select cells by ID. Replaces the viewer's selection
        #'   and turns cross-filter mode off so it shows as is.
        #' @param ids Character vector of cell IDs to select (empty vector clears).
        set_selection = function(ids) {
            ids <- as.character(ids)
            idx <- match(ids, private$cell_ids)
            if (anyNA(idx))
                warning("[LensViewer] ", sum(is.na(idx)), " ID(s) are not cells ",
                    "in the viewer and were ignored", call. = FALSE)
            idx <- unique(idx[!is.na(idx)])
            rule <- list(source = "r", kind = "ids",
                params = list(mask = .encode_mask(idx, length(private$cell_ids))))
            self$select(rule, combine = "or")
        },

        #' @description Select cells with a rule, the same way the viewer's
        #'   tools do. The rule is evaluated in R over cell centroids and pushed
        #'   metadata (so it works with no browser open), and sent to every tab.
        #' @param rule A rule list, e.g.
        #'   `list(kind = "polygon", space = "spatial", params = list(rings = list(m)))`
        #'   with `m` a two-column matrix, or one of the helpers' results:
        #'   [lens_polygon()], [lens_bbox()], [lens_range()], [lens_categories()],
        #'   [lens_compare()], [lens_cells()], [lens_union()].
        #'   `NULL` clears the selection.
        #' @param source Which source the rule replaces (default `"r"`).
        #' @param replace Clear the other sources first (default `TRUE`).
        #' @param combine `"or"` (union of sources) or `"and"` (cross-filter);
        #'   `NULL` keeps the current mode.
        #' @return The selected cell IDs, invisibly.
        select = function(rule, source = "r", replace = TRUE, combine = NULL) {
            if (!is.null(rule)) {
                rule <- .resolve_cells(rule, private$cell_ids)
                rule$source <- source
                .validate_rule(rule)
            }
            rules <- if (replace) list() else private$rule_set
            rules[[source]] <- rule
            if (!is.null(combine)) private$combine <- match.arg(combine, c("or", "and"))
            private$rule_set <- rules
            if (!is.null(private$cell_ids)) {
                hit <- .combine_rules(rules, private$eval_ctx(), private$combine)
                self$selection <- private$cell_ids[hit]
            }
            self$selection_rules <- unname(rules)
            if (self$connected())
                self$send("set_rule", list(source = source, rule = rule,
                    replace = replace, combine = private$combine))
            invisible(self$selection)
        },

        #' @description Read the viewer's state from the first connected tab:
        #'   config (layers, colouring, rules, mode), view and counts.
        #' @param timeout Seconds to wait for the browser
        state = function(timeout = 10) private$request("get_state", NULL, timeout),

        #' @description Move the camera.
        #' @param x,y Centre in data coordinates
        #' @param zoom deck.gl zoom (log2 pixels per unit)
        #' @param bounds `c(xmin, xmax, ymin, ymax)` to fit instead
        set_view = function(x = NULL, y = NULL, zoom = NULL, bounds = NULL) {
            target <- if (!is.null(x) && !is.null(y)) c(x, y)
            private$request("set_view", list(target = target, zoom = zoom, bounds = bounds))
        },

        #' @description Colour cells by a pushed metadata column (`NULL` for none)
        #' @param column Column name
        color_by = function(column = NULL) {
            private$request("set_color_by", list(column = column))
            invisible(self)
        },

        #' @description Show or hide a layer, or set its opacity
        #' @param name `"poly"`, `"tx"` or `"annotations"`
        #' @param show,alpha Visibility and opacity (0–1); `NULL` leaves as is
        set_layer = function(name, show = NULL, alpha = NULL) {
            private$request("set_layer", list(name = name, show = show, alpha = alpha))
            invisible(self)
        },

        #' @description Highlight genes in the transcript layer
        #' @param genes Gene names
        show_genes = function(genes) {
            r <- private$request("set_genes", list(genes = as.list(as.character(genes))))
            if (r$matched < length(genes))
                warning("[LensViewer] ", length(genes) - r$matched, " gene(s) not in the panel",
                    call. = FALSE)
            invisible(self)
        },

        #' @description Save a PNG of the spatial view
        #' @param file Output path (default a temp file)
        #' @return The file path, invisibly.
        screenshot = function(file = tempfile(fileext = ".png")) {
            r <- private$request("screenshot")
            writeBin(jsonlite::base64_dec(sub("^data:image/png;base64,", "", r$png)), file)
            invisible(file)
        },

        #' @description Recent user actions and browser errors, newest last
        #' @param n Number of entries
        log = function(n = 20L) {
            entries <- utils::tail(private$log_entries, n)
            data.frame(
                time   = as.POSIXct(vapply(entries, `[[`, 0, "time"), origin = "1970-01-01"),
                action = vapply(entries, `[[`, "", "action"),
                detail = vapply(entries, function(e)
                    as.character(jsonlite::toJSON(e$detail, auto_unbox = TRUE)), "")
            )
        },

        #' @description A plain-text summary of the viewer for a person or an
        #'   agent that cannot see the screen: the view in data coordinates,
        #'   layers, colouring, the selection and its rules, and optionally what
        #'   the selection holds in one metadata column.
        #' @param by Metadata column to break the selection down by (pushed
        #'   with `push_metadata()`); categories are counted, numbers summarised
        #' @param top Number of categories to list
        #' @return A `lens_description` list; printing it gives the summary.
        describe = function(by = NULL, top = 10L) {
            st  <- if (self$connected())
                tryCatch(self$state(timeout = 5), error = function(e) NULL)
            n   <- length(private$cell_ids)
            out <- list(
                url = self$url, connected = self$connected(), n_cells = n,
                view = st$view, color_by = st$config$colorBy,
                layers = if (!is.null(st)) vapply(st$config$layers, function(l) isTRUE(l$show), NA),
                combine = private$combine,
                rules = vapply(private$rule_set, function(r) r$kind %||% "", ""),
                selected = length(self$selection),
                metadata = names(private$meta_table)
            )
            if (n && !is.null(st$view$bounds)) {
                b   <- unlist(st$view$bounds)
                ctx <- private$eval_ctx()
                out$in_view <- sum(ctx$x >= b[1L] & ctx$x <= b[2L] & ctx$y >= b[3L] & ctx$y <= b[4L])
            }
            if (!is.null(by)) {
                v <- private$meta_table[[by]]
                if (is.null(v))
                    stop("[LensViewer] no metadata column '", by, "'; pushed: ",
                        paste(names(private$meta_table), collapse = ", "), call. = FALSE)
                v <- v[match(self$selection, private$cell_ids)]
                out$by <- by
                out$breakdown <- if (is.numeric(v) && !is.factor(v)) summary(v)
                    else utils::head(sort(table(v, useNA = "ifany"), decreasing = TRUE), top)
            }
            structure(out, class = "lens_description")
        },

        #' @description The rules behind the current selection, one row per
        #'   source, with a readable summary and how many cells each matches on
        #'   its own (which shows what is narrowing a cross-filter).
        #' @param code Instead, print R code that recreates the selection with
        #'   the `lens_*()` builders, to copy, adjust and re-run.
        #' @return A `lens_rules` data frame, or (with `code = TRUE`) the code
        #'   lines, invisibly.
        rules = function(code = FALSE) {
            rules <- private$rule_set
            ctx <- if (length(rules) && !is.null(private$cell_ids)) private$eval_ctx()
            if (code) {
                lines <- character()
                for (i in seq_along(rules)) {
                    tail <- if (i == 1L) sprintf(', combine = "%s"', private$combine)
                            else ", replace = FALSE"
                    lines <- c(lines, sprintf('viewer$select(%s,\n    source = "%s"%s)',
                        .rule_code(rules[[i]], private$cell_ids, ctx), names(rules)[i], tail))
                }
                if (!length(lines)) lines <- "viewer$select(NULL)  # nothing selected"
                cat(lines, sep = "\n\n")
                cat("\n")
                return(invisible(lines))
            }
            count <- function(r) if (is.null(ctx)) NA_integer_ else
                tryCatch(sum(.eval_rule(r, ctx)), error = function(e) NA_integer_)
            out <- data.frame(
                source  = names(rules) %||% character(),
                kind    = vapply(rules, function(r) r$kind %||% "", ""),
                cells   = vapply(rules, count, 1L),
                summary = vapply(rules, .rule_summary, ""),
                stringsAsFactors = FALSE
            )
            rownames(out) <- NULL
            structure(out, class = c("lens_rules", "data.frame"),
                combine = private$combine, selected = length(self$selection))
        },

        #' @description Wait until the user changes the selection in the
        #'   browser (a lasso, brush, histogram brush, ...), then return it. Lets
        #'   an agent ask the user to draw a region and read the result. Press
        #'   Esc / interrupt to stop waiting.
        #' @param timeout Seconds to wait
        #' @param nonempty Keep waiting through changes that clear the selection
        #' @return The selected cell IDs.
        wait_for_selection = function(timeout = 300, nonempty = TRUE) {
            if (!self$connected())
                stop("[LensViewer] no viewer connected", call. = FALSE)
            start <- private$sel_seq
            t0 <- Sys.time()
            repeat {
                if (private$sel_seq != start && (!nonempty || length(self$selection))) break
                if (as.numeric(Sys.time() - t0, units = "secs") > timeout)
                    stop("[LensViewer] no selection within ", timeout, " s", call. = FALSE)
                later::run_now(0.05)
            }
            self$selection
        },

        #' @description The selected cells as a Giotto object, through
        #'   `GiottoClass::subsetGiotto()`.
        #' @param gobject The giotto object the viewer was launched from
        #' @param spat_unit Spatial unit of the selection (default: the one the
        #'   viewer shows)
        #' @param feat_type Feature type, passed to `subsetGiotto()`
        subset = function(gobject, spat_unit = NULL, feat_type = "rna") {
            if (!length(self$selection))
                stop("[LensViewer] nothing is selected", call. = FALSE)
            if (!requireNamespace("GiottoClass", quietly = TRUE))
                stop("[LensViewer] subset() needs GiottoClass", call. = FALSE)
            # No `...` here: subsetGiotto() records its caller's call with
            # match.call(), which fails on a forwarded `...`
            su <- spat_unit %||% private$spat_unit %||% "cell"
            ids <- self$selection
            GiottoClass::subsetGiotto(gobject, spat_unit = su, feat_type = feat_type,
                cell_ids = ids)
        },

        #' @description The data-space box on screen, `c(xmin, xmax, ymin, ymax)`
        view_bounds = function() {
            b <- unlist(self$state()$view$bounds)
            stats::setNames(b, c("xmin", "xmax", "ymin", "ymax"))
        },

        #' @description Fit the view to cells (default: the selection)
        #' @param ids Cell IDs
        #' @param pad Margin around them, as a fraction of their extent
        zoom_to = function(ids = self$selection, pad = 0.1) {
            idx <- match(as.character(ids), private$cell_ids)
            idx <- idx[!is.na(idx)]
            if (!length(idx)) stop("[LensViewer] none of the IDs are cells in the viewer", call. = FALSE)
            ctx <- private$eval_ctx()
            x <- range(ctx$x[idx]); y <- range(ctx$y[idx])
            px <- max(diff(x), 1) * pad; py <- max(diff(y), 1) * pad
            invisible(self$set_view(bounds = c(x[1L] - px, x[2L] + px, y[1L] - py, y[2L] + py)))
        },

        #' @description Show a Vega-Lite chart in one of the stats panes, for
        #'   example from `GiottoVisuals::renderSpec(..., engine = "vegalite")`.
        #'   Rows with a `cell_ID` are linked to the viewer: they dim when not
        #'   selected, and an interval param named `brush` selects their cells.
        #' @param spec A Vega-Lite spec (list or JSON string) with inline
        #'   `data$values`, or a spec without data plus `data`
        #' @param data Optional data.frame for the spec (large data is sent as
        #'   a parquet file rather than inline)
        #' @param pane Stats pane to replace (1 or 2)
        #' @param title Pane title
        push_panel = function(spec, data = NULL, pane = 2L, title = NULL) {
            if (is.character(spec)) spec <- jsonlite::fromJSON(spec, simplifyVector = FALSE)
            taken <- .spec_take_data(unclass(spec))
            spec  <- taken$spec
            rows  <- data %||% taken$rows
            payload <- list(pane = as.integer(pane), title = title, spec = spec)
            if (!is.null(rows)) {
                rows <- as.data.frame(rows)
                if ("cell_ID" %in% names(rows) && !is.null(private$cell_ids)) {
                    idx <- match(as.character(rows$cell_ID), private$cell_ids)
                    rows <- rows[!is.na(idx), , drop = FALSE]
                    rows$`_idx` <- idx[!is.na(idx)] - 1L
                }
                if (nrow(rows) > 5000L) {
                    dir <- file.path(private$session, "panels")
                    dir.create(dir, showWarnings = FALSE)
                    f <- sprintf("panel_%d_%.0f.parquet", pane, as.numeric(Sys.time()) * 1000)
                    arrow::write_parquet(rows, file.path(dir, f))
                    payload$data_url <- paste0("session/panels/", f)
                } else {
                    payload$spec$data <- list(values = rows)
                }
            }
            self$send("push_panel", payload)
            invisible(self)
        },

        #' @description Push polygon overlays from R into the viewer.
        #'   Polygons are rendered as a semi-transparent layer above the overview
        #'   and below cell outlines.  Useful for spatial domains, tissue regions,
        #'   or any custom geometry in the same coordinate space as the data.
        #' @param x      A `terra::SpatVector`, `sf` object, or character vector
        #'   of WKT strings — all with POLYGON/MULTIPOLYGON geometries in the
        #'   same coordinate space as the spatial data.
        #' @param names  Optional character vector of names (one per row).
        #'   Falls back to an `x$name` column if present, else blank.
        push_polygons = function(x, names = NULL) {
            if (!self$connected()) {
                warning("[LensViewer] no viewer connected yet", call. = FALSE)
                return(invisible(self))
            }
            self$send("push_polygons", list(polygons = .prep_overlay_polys(x, names)))
            invisible(self)
        },

        #' @description Register a callback for a viewer message type
        #' @param type One of `"cell_selection"`, `"annotations_update"`
        #' @param callback Function of one argument, the message data
        on = function(type, callback) {
            if (!is.character(type) || length(type) != 1L ||
                !type %in% .lens_callback_types) {
                stop("[LensViewer] `type` must be one of: ",
                    paste(.lens_callback_types, collapse = ", "), call. = FALSE)
            }
            private$cbs[[type]] <- callback
            invisible(self)
        },

        #' @description Stop the server and remove this viewer's temp files
        close = function() {
            if (!is.null(private$server)) {
                private$server$stop()
                private$server <- NULL
                rm(list = ls(private$conns), envir = private$conns)
                unlink(private$session, recursive = TRUE)
                key <- as.character(self$port)
                if (identical(.lens_registry[[key]], self))
                    rm(list = key, envir = .lens_registry)
                message("[LensViewer] server stopped")
            }
            invisible(self)
        },

        #' @description Print a summary
        #' @param ... Ignored
        print = function(...) {
            cat("LensViewer\n")
            cat("  url:         ", self$url, "\n")
            cat("  running:     ", !is.null(private$server), "\n")
            cat("  connected:   ", length(private$conns), "tab(s)\n")
            cat("  selection:   ", length(self$selection), "cell(s)\n")
            cat("  annotations: ", length(self$annotations), "polygon(s)\n")
            invisible(self)
        }
    ),

    private = list(
        token       = NULL,
        session     = NULL,
        cell_ids    = NULL,
        spat_unit   = NULL,
        sel_seq     = 0L,
        server      = NULL,
        conns       = NULL,
        cbs         = list(),
        cached_meta = NULL,
        meta_table  = NULL,
        rule_set    = list(),
        combine     = "or",
        next_id     = 0L,
        req_id      = 0L,
        replies     = list(),
        log_entries = list(),

        cells_xy    = NULL,

        eval_ctx = function() {
            if (is.null(private$cells_xy)) {
                cells <- arrow::read_parquet(file.path(private$session, "cells.parquet"),
                    col_select = c("x", "y"))
                # As float32, exactly what the browser tests against
                private$cells_xy <- list(x = as.numeric(cells$x), y = as.numeric(cells$y))
            }
            c(private$cells_xy, list(meta = private$meta_table))
        },

        # Send a request to the first tab and wait for its reply
        request = function(type, data = NULL, timeout = 10) {
            if (!self$connected())
                stop("[LensViewer] no viewer connected", call. = FALSE)
            private$req_id <- private$req_id + 1L
            id <- as.character(private$req_id)
            ws <- as.list(private$conns)[[1L]]
            ws$send(.encode_ws_message(type, data, id = id))
            t0 <- Sys.time()
            while (is.null(private$replies[[id]])) {
                if (as.numeric(Sys.time() - t0, units = "secs") > timeout)
                    stop("[LensViewer] the viewer did not answer '", type, "' within ",
                        timeout, " s", call. = FALSE)
                later::run_now(0.02)
            }
            r <- private$replies[[id]]
            private$replies[[id]] <- NULL
            if (!is.null(r$error))
                stop("[LensViewer] ", type, ": ", r$error, call. = FALSE)
            r$data
        },

        add_log = function(action, detail) {
            entry <- list(time = as.numeric(Sys.time()), action = action, detail = detail)
            private$log_entries <- utils::tail(c(private$log_entries, list(entry)), 200L)
        },

        broadcast = function(json) {
            for (ws in as.list(private$conns)) try(ws$send(json), silent = TRUE)
        },

        start_server = function(host, mounts) {
            priv <- private
            pub  <- self
            handlers <- list(
                open = function(ws) {
                    priv$next_id <- priv$next_id + 1L
                    id <- as.character(priv$next_id)
                    assign(id, ws, envir = priv$conns)
                },
                message = function(ws, msg) {
                    parsed <- .parse_ws_message(msg)
                    if (is.null(parsed)) return(invisible())
                    dat <- parsed$data
                    switch(parsed$type,
                        # The tab has registered its handlers: send what it
                        # needs, so a reload or new tab matches the others
                        ready = {
                            if (!identical(as.integer(dat$protocol), .lens_protocol))
                                warning("[LensViewer] the viewer bundle speaks protocol ",
                                    .console_text(dat$protocol %||% "?"), ", this package ", .lens_protocol,
                                    "; reinstall GiottoLens or rebuild inst/viewer", call. = FALSE)
                            if (!is.null(priv$cached_meta))
                                ws$send(.encode_ws_message("load_metadata", priv$cached_meta))
                            if (length(priv$rule_set))
                                for (src in names(priv$rule_set))
                                    ws$send(.encode_ws_message("set_rule", list(source = src,
                                        rule = priv$rule_set[[src]], replace = FALSE,
                                        combine = priv$combine)))
                        },
                        reply = if (!is.null(parsed$id))
                            priv$replies[[as.character(parsed$id)]] <- list(
                                data = dat, error = parsed$error),
                        client_error = {
                            priv$add_log("error", dat)
                            message("[GiottoLens viewer] ", .console_text(dat$where), ": ",
                                .console_text(dat$message))
                        },
                        log = priv$add_log(dat$action %||% "", dat$detail),
                        {
                            tryCatch(.handle_ws_message(pub, parsed, priv$cell_ids),
                                error = function(e) warning("[LensViewer] message error: ",
                                    .console_text(conditionMessage(e)), call. = FALSE))
                            if (parsed$type == "cell_selection") {
                                priv$sel_seq <- priv$sel_seq + 1L
                                rules <- dat$rules %||% list()
                                names(rules) <- vapply(rules, function(r) r$source %||% "", "")
                                priv$rule_set   <- rules
                                priv$combine <- dat$combine %||% "or"
                            }
                            cb <- priv$cbs[[parsed$type]]
                            if (!is.null(cb)) later::later(function() cb(dat))
                        }
                    )
                },
                close = function(ws) {
                    for (id in ls(priv$conns))
                        if (identical(get(id, envir = priv$conns), ws))
                            rm(list = id, envir = priv$conns)
                }
            )
            private$server <- tryCatch(
                httpuv::startServer(host, self$port, .lens_app(
                    viewer_dir  = .viewer_dir(),
                    session_dir = private$session,
                    mounts      = mounts,
                    token       = private$token,
                    ws_handlers = handlers,
                    # RStudio Server's proxy changes the Origin; the token
                    # still guards the socket
                    check_origin = .ide() != "rstudio-server"
                )),
                error = function(e) {
                    unlink(private$session, recursive = TRUE)
                    stop("[LensViewer] could not start a server on ", host, ":",
                        self$port, " (in use?): ", conditionMessage(e),
                        call. = FALSE)
                }
            )
        }
    )
)


# ── Helpers ───────────────────────────────────────────────────────────────────

#' @export
print.lens_description <- function(x, ...) {
    line <- function(k, v) cat(sprintf("  %-10s %s\n", k, v))
    cat("GiottoLens viewer\n")
    line("url", x$url)
    line("browser", if (x$connected) "connected" else "not connected")
    line("cells", format(x$n_cells, big.mark = ","))
    if (!is.null(x$view)) {
        b <- signif(unlist(x$view$bounds), 6)
        line("view", sprintf("x %s to %s, y %s to %s (zoom %.2f)", b[1], b[2], b[3], b[4], x$view$zoom))
        if (!is.null(x$in_view)) line("in view", paste(format(x$in_view, big.mark = ","), "cells"))
        line("layers", paste(names(x$layers)[x$layers], collapse = ", "))
        line("colour by", x$color_by %||% "none")
    }
    line("selected", sprintf("%s cells%s", format(x$selected, big.mark = ","),
        if (length(x$rules)) sprintf(" (%s: %s)", if (x$combine == "and") "AND" else "OR",
            paste(names(x$rules), x$rules, sep = "=", collapse = ", ")) else ""))
    if (length(x$metadata)) line("metadata", paste(x$metadata, collapse = ", "))
    if (!is.null(x$breakdown)) {
        cat(sprintf("  selection by %s:\n", x$by))
        print(x$breakdown)
    }
    invisible(x)
}

# Pull a spec's data out so it can be linked and sent separately: inline
# `data$values`, or a single entry of `datasets` (GiottoVisuals' renderSpec()
# shape) whose `data: {name}` references become the viewer's "cells".
.spec_take_data <- function(spec) {
    rows <- spec$data$values
    spec$data <- NULL
    if (is.null(rows) && length(spec$datasets) == 1L) {
        name <- names(spec$datasets)
        rows <- spec$datasets[[1L]]
        spec$datasets <- NULL
        rename <- function(x) {
            if (!is.list(x)) return(x)
            if (identical(x$data, list(name = name))) x$data <- list(name = "cells")
            x[] <- lapply(x, rename)
            x
        }
        spec <- rename(spec)
    } else if (length(spec$datasets) > 1L) {
        stop("[push_panel] specs with more than one dataset are not supported yet",
            call. = FALSE)
    }
    list(spec = spec, rows = rows)
}

.viewer_dir <- function() {
    dir <- system.file("viewer", package = "GiottoLens")
    if (!nzchar(dir) || !file.exists(file.path(dir, "index.html")))
        stop("[GiottoLens] cannot find the viewer bundle; reinstall GiottoLens ",
            "or run `npm run build` in inst/viewer-src", call. = FALSE)
    dir
}

# Convert polygon input to a list of {name, coords} for push_polygons.
# Accepts terra SpatVector (preferred), sf object, or WKT character vector.
.prep_overlay_polys <- function(x, poly_names) {
    if (!requireNamespace("terra", quietly = TRUE))
        stop("[push_polygons] package 'terra' is required", call. = FALSE)
    if (inherits(x, "SpatVector")) {
        sv <- x
    } else if (inherits(x, c("sf", "sfc"))) {
        sv <- terra::vect(x)
    } else if (is.character(x)) {
        if (!length(x)) return(list())
        sv <- terra::vect(x, crs = "local")
    } else {
        stop("[push_polygons] x must be a terra SpatVector, sf object, ",
             "or character vector of WKT strings", call. = FALSE)
    }

    if (terra::geomtype(sv) != "polygons")
        stop("[push_polygons] x must contain polygon geometries", call. = FALSE)

    n   <- nrow(sv)
    df  <- terra::values(sv)
    nms <- if (!is.null(poly_names)) as.character(poly_names)
           else if ("name" %in% names(df)) as.character(df[["name"]])
           else rep("", n)

    # Exterior ring of the first part of each geometry.
    # terra::geom() columns: geom, part, x, y, hole
    gmat <- terra::geom(sv)
    keep <- gmat[, "part"] == 1 & gmat[, "hole"] == 0
    gmat <- gmat[keep, , drop = FALSE]
    rows <- split(seq_len(nrow(gmat)), gmat[, "geom"])
    lapply(seq_len(n), function(i) {
        r <- rows[[as.character(i)]]
        list(
            name   = nms[[i]],
            # unname() so jsonlite writes [x, y] pairs, not objects
            coords = lapply(r, function(j) unname(gmat[j, c("x", "y")]))
        )
    })
}
