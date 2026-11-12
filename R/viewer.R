# ── launch_lens() ────────────────────────────────────────────────────────────

#' Launch the GiottoLens viewer
#'
#' Starts a combined HTTP + WebSocket server via httpuv and opens the viewer.
#' The viewer bundle and the GiottoDisk stores are served in place; only the
#' manifest and pushed metadata are written, to a per-viewer temp directory.
#' Tile data goes through a Range-aware handler so the viewer reads only the
#' columns it draws.
#'
#' @param x          A giotto object, or `NULL` (default) to start without
#'   one and load it later with `viewer$set_object()`. A giottoPoints backed
#'   by a GiottoDisk tile store still works but is deprecated: pass a giotto
#'   object.
#' @param gpolygons  giottoPolygon backed by a GiottoDisk tile store, with a
#'   giottoPoints `x` (deprecated). Ignored when `x` is a giotto object.
#' @param feat_type  Feature type key when `x` is a giotto object (default
#'   `"rna"`). `NULL` launches without transcripts.
#' @param spat_unit  Spatial unit key when `x` is a giotto object (default
#'   `"cell"`). Its polygons are the cells; a spatial unit without polygons
#'   uses its spatial locations, such as Visium spots or VisiumHD bins. `NULL`
#'   launches without cells.
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
#' @param images     Images to show under the cells when `x` is a giotto
#'   object: `NULL` (default) for all of its images, image names, or `FALSE`
#'   for none. The first is shown at launch and the others are listed, off.
#'   The viewer reads each image's TIFF file (`@file_path`) in place, by
#'   tile; images without one are skipped with a message.
#' @param image_files Image files to show besides the object's images, such
#'   as an H&E to register: a character vector of paths, named by image
#'   (default: the file name). They are drawn inside the data's extent until
#'   registered with `viewer$register_image()`.
#' @param mark       How cells without polygons are drawn once zoomed in: a
#'   list with any of `shape` (`"circle"`, `"square"` or `"hex"`), `size`
#'   (across, in data units) and `angle` (degrees). Fields left out are worked
#'   out: bins with `array_row` and `array_col` in their cell metadata are
#'   squares fitted to the bin grid, other cells circles as wide as the median
#'   distance to their nearest neighbour. Polygon cells are drawn as dots
#'   until their outlines load, or as this mark when one is given.
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
    transfer   = c("auto", "whole", "columns"),
    images     = NULL,
    mark       = NULL,
    image_files = NULL
) {
    transfer <- match.arg(transfer)
    # Checked before the server starts, so a bad argument leaves none running
    object <- if (!is.null(x) || !is.null(gpolygons)) .resolve_object(x,
        gpolygons = gpolygons, feat_type = feat_type, spat_unit = spat_unit,
        images = images, image_files = image_files, mark = mark)

    port <- if (is.null(port)) httpuv::randomPort(host = host) else as.integer(port)
    old  <- .lens_registry[[as.character(port)]]
    if (!is.null(old)) {
        message("[launch_lens] closing the viewer already on port ", port)
        old$close()
    }
    url_prefix <- sub("/+$", "", url_prefix %||% paste0("http://127.0.0.1:", port))

    viewer <- LensViewer$new(port = port, host = host, url_prefix = url_prefix,
        transfer = transfer, object = object)
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

# What launch_lens() and set_object() load: the layers, images and mark,
# checked.
.resolve_object <- function(x, gpolygons = NULL, feat_type = "rna", spat_unit = "cell",
                            images = NULL, image_files = NULL, mark = NULL) {
    giotto <- inherits(x, "giotto")
    if (!giotto) .warn_layer_launch()
    mark   <- .check_mark(mark)
    layers <- .resolve_layers(x, gpolygons, feat_type, spat_unit)
    imgs   <- .pick_images(x, images)
    list(
        layers      = layers,
        images      = imgs,
        image_files = .check_image_files(image_files, taken = names(imgs)),
        mark        = mark,
        spat_unit   = if (giotto) spat_unit
    )
}

# Once per session: the tests and scripts that still do it see it once
.warn_layer_launch <- function() {
    if (isTRUE(.lens_warned$layers)) return(invisible())
    .lens_warned$layers <- TRUE
    warning("[launch_lens] launching from giottoPoints / giottoPolygon layers is ",
        "deprecated; pass a giotto object", call. = FALSE)
}
.lens_warned <- new.env(parent = emptyenv())

.resolve_layers <- function(x, gpolygons, feat_type, spat_unit) {
    locations <- NULL
    if (inherits(x, "giotto")) {
        gpoints <- .pick_layer(x@feat_info, feat_type, "feat_type")
        # Cells are the spatial unit's polygons, or else its spatial locations
        # (adr/0010)
        gpolygons <- NULL
        if (!is.null(spat_unit) && !spat_unit %in% names(x@spatial_info) &&
            spat_unit %in% names(x@spatial_locs)) {
            locations <- .spat_locations(x, spat_unit)
        } else {
            gpolygons <- .pick_layer(x@spatial_info, spat_unit, "spat_unit",
                also = names(x@spatial_locs))
        }
    } else {
        gpoints <- x
    }
    if (is.null(gpoints) && is.null(gpolygons) && is.null(locations))
        stop("[launch_lens] nothing to show: provide points and/or cells",
            call. = FALSE)
    .check_tile_store(gpoints, "giottoPoints", "points")
    .check_tile_store(gpolygons, "giottoPolygon", "polygons")
    list(gpoints = gpoints, gpolygons = gpolygons, locations = locations)
}

# A spatial unit's spatial locations as the cell table's source (`xy`: cell_ID,
# x, y), with the bin grid (`grid`: row, col per cell) when its cell metadata
# has array_row and array_col.
.spat_locations <- function(x, spat_unit) {
    sl <- GiottoClass::getSpatialLocations(x, spat_unit = spat_unit, output = "data.table")
    xy <- data.frame(cell_ID = as.character(sl$cell_ID), x = as.numeric(sl$sdimx),
        y = as.numeric(sl$sdimy))
    bad <- !is.finite(xy$x) | !is.finite(xy$y)
    if (any(bad)) {
        message("[launch_lens] ", sum(bad), " cell(s) without a location are not shown")
        xy <- xy[!bad, , drop = FALSE]
    }
    if (!nrow(xy))
        stop(sprintf("[launch_lens] spat_unit '%s' has no spatial locations", spat_unit),
            call. = FALSE)
    grid <- NULL
    if (length(GiottoClass::list_cell_metadata(x, spat_unit = spat_unit))) {
        meta <- GiottoClass::pDataDT(x, spat_unit = spat_unit)
        if (all(c("array_row", "array_col") %in% names(meta))) {
            i <- match(xy$cell_ID, as.character(meta$cell_ID))
            grid <- data.frame(row = meta$array_row[i], col = meta$array_col[i])
        }
    }
    list(xy = xy, grid = grid)
}

# `also`: further keys that would have been accepted, for the error message
.pick_layer <- function(slot_list, key, arg, also = NULL) {
    if (is.null(key)) return(NULL)
    if (!key %in% names(slot_list)) {
        keys <- unique(c(names(slot_list), also))
        stop(sprintf("[launch_lens] %s '%s' not found; available: %s (or NULL to skip)",
            arg, key, if (length(keys)) paste(keys, collapse = ", ") else "none"),
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
        #' @field registration The image being registered in the viewer, or
        #'   `NULL`: image and reference names, the landmark pairs (`moving_x`,
        #'   `moving_y` in image pixels, `fixed_x`, `fixed_y` in data
        #'   coordinates, `residual`), and `transform`, the 3 x 3 matrix from
        #'   image pixels to data coordinates (the affine fit from three
        #'   complete pairs on, the placement before). See
        #'   [registration_matrix()] and [write_registration()].
        registration = NULL,

        #' @description Start a viewer server. Use [launch_lens()] instead.
        #' @param port,host Where to listen
        #' @param url_prefix Base URL the browser uses
        #' @param transfer Tile transfer mode, see [launch_lens()]
        #' @param object What to show, from `.resolve_object()` (internal), or
        #'   `NULL` to start without an object
        initialize = function(port, host, url_prefix, transfer = "auto", object = NULL) {
            self$port         <- port
            private$transfer  <- transfer
            private$token     <- .rand_id(24L)
            private$conns     <- new.env(parent = emptyenv())
            private$conn_load <- new.env(parent = emptyenv())
            private$routes    <- new.env(parent = emptyenv())
            private$routes$mounts <- list()
            private$routes$images <- list()
            private$session   <- file.path(tempdir(), "giottolens",
                paste0(port, "-", .rand_id(8L)))
            dir.create(file.path(private$session, "metadata"),
                recursive = TRUE, showWarnings = FALSE)
            self$url <- paste0(url_prefix, .lens_root(private$token), "/")
            private$start_server(host)
            assign(as.character(port), self, envir = .lens_registry)
            tryCatch(if (is.null(object)) private$load_empty() else private$load(object),
                error = function(e) {
                    self$close()
                    stop(e)
                })
        },

        #' @description Show another object in this viewer. The server and its
        #'   URL stay; open tabs reload. Nothing of the current object is kept:
        #'   its settings, rules, annotations, pushed panels and metadata are
        #'   dropped, with a warning naming the rules, annotations and panels
        #'   lost. Returns before the tabs have reloaded.
        #' @param x,gpolygons,feat_type,spat_unit,images,image_files,mark As in
        #'   [launch_lens()]
        set_object = function(x, gpolygons = NULL, feat_type = "rna", spat_unit = "cell",
                              images = NULL, image_files = NULL, mark = NULL) {
            private$load(.resolve_object(x, gpolygons = gpolygons, feat_type = feat_type,
                spat_unit = spat_unit, images = images, image_files = image_files,
                mark = mark))
            invisible(self)
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
            private$need_object("LensViewer$push_metadata")
            meta <- if (inherits(x, "giotto")) {
                prep_meta(x, cols = cols, dimreds = dimreds, dims = dims,
                    spat_unit = spat_unit, feat_type = feat_type)
            } else {
                as.data.frame(x)
            }
            # A type given here replaces one kept from set_column_type()
            if (inherits(x, "giotto")) {
                casts <- .parse_col_types(cols)
                given <- gsub("[^A-Za-z0-9_]", "_", names(casts)[!is.na(casts)])
                private$col_types[given] <- NULL
            }
            out <- .write_metadata(meta, file.path(private$session, "metadata"),
                private$cell_ids, types = unlist(private$col_types))
            rm(meta)
            private$col_types[out$dropped] <- NULL
            private$meta_values <- out$values
            msg <- private$publish_meta(out)
            message("[LensViewer] metadata: ", length(msg$columns), " column(s): ",
                paste(vapply(msg$columns, `[[`, "", "name"), collapse = ", "),
                if (!self$connected()) " (sent when the viewer connects)")
            invisible(self)
        },

        #' @description Show a numeric metadata column as categories (one
        #'   per distinct value, at most 1000) or as a continuous scale.
        #'   Integer and double columns are continuous by default. The
        #'   viewer's "treat as" menu in the cells panel sets the same. Rules
        #'   on the column are dropped, and the metadata is sent again.
        #'   The setting is kept for later `push_metadata()` calls, unless
        #'   one sets the column's type through `cols`.
        #' @param column Column name, as pushed
        #' @param type `"categorical"` or `"continuous"`
        set_column_type = function(column, type = c("categorical", "continuous")) {
            private$need_object("LensViewer$set_column_type")
            type <- match.arg(type)
            if (is.null(private$cached_meta))
                stop("[LensViewer] no metadata pushed yet", call. = FALSE)
            if (!is.character(column) || length(column) != 1L)
                stop("[LensViewer] `column` must be one column name", call. = FALSE)
            entry <- private$meta_entry(column)
            if (is.null(entry))
                stop("[LensViewer] no metadata column '", column, "'", call. = FALSE)
            if (!isTRUE(entry$numeric))
                stop("[LensViewer] '", column, "' is not numeric; only numeric columns ",
                    "change type", call. = FALSE)
            if (entry$kind != type) {
                re <- .retype_meta(private$meta_dir(), entry, type,
                    private$meta_values[[column]])
                private$meta_values[column] <- list(re$values)
                msg <- private$cached_meta
                msg$columns[[match(column, private$meta_names())]] <- re$entry
                private$publish_meta(list(msg = msg), drop_rules_on = column)
            }
            private$col_types[[column]] <- type
            invisible(self)
        },

        #' @description Select cells by ID. Replaces the viewer's selection
        #'   and turns cross-filter mode off so it shows as is.
        #' @param ids Character vector of cell IDs to select (empty vector clears).
        set_selection = function(ids) {
            private$need_object("LensViewer$set_selection")
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
            private$need_object("LensViewer$select")
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
            private$broadcast(private$rule_message(list(source = source, rule = rule,
                replace = replace, combine = private$combine)))
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
        #' @param name `"poly"`, `"tx"`, `"annotations"` or `"img"` (all images)
        #' @param show,alpha Visibility and opacity (0–1); `NULL` leaves as is
        set_layer = function(name, show = NULL, alpha = NULL) {
            private$request("set_layer", list(name = name, show = show, alpha = alpha))
            invisible(self)
        },

        #' @description Set how cells are drawn once zoomed in: as dots, or as
        #'   circles, squares or hexagons of a size and angle. Fields given
        #'   replace the viewer's and the others stay; with no arguments the
        #'   mark goes back to the one from launch (see `launch_lens(mark =)`).
        #'   The setting is saved with the viewer's and survives a reload. Cells
        #'   with polygons show their outlines over any mark once zoomed in
        #'   close.
        #' @param shape `"circle"`, `"square"` or `"hex"`
        #' @param size Width in data units (a hexagon across its flats)
        #' @param angle Rotation in degrees, for squares and hexagons
        #' @param show `FALSE` draws dots, `TRUE` the mark
        set_mark = function(shape = NULL, size = NULL, angle = NULL, show = NULL) {
            if (is.null(private$cells))
                stop("[set_mark] the viewer has no cells", call. = FALSE)
            m <- Filter(Negate(is.null), list(shape = shape, size = size, angle = angle))
            if (length(m)) .check_mark(m, "set_mark")
            if (!is.null(show)) {
                if (!(is.logical(show) && length(show) == 1L && !is.na(show)))
                    stop("[set_mark] show is TRUE or FALSE", call. = FALSE)
                m$show <- show
            }
            private$request("set_mark", if (length(m)) list(mark = m) else list(reset = TRUE))
            invisible(self)
        },

        #' @description Set the color scale of a continuous metadata column:
        #'   a preset, or custom colors spaced evenly from the column's
        #'   minimum to its maximum. The viewer's legend sets the same values.
        #'   `NULL` arguments leave a setting as is.
        #' @param column Continuous column; `NULL` for the column cells are
        #'   colored by
        #' @param preset One of `"viridis"` (the default), `"blue-red"`,
        #'   `"magma"`, `"inferno"`, `"plasma"`, `"cividis"`, `"turbo"`,
        #'   `"gray"`, `"blue-white-red"`
        #' @param colors 2 to 9 colors (names or hex strings), low to high;
        #'   sets a custom scale
        #' @param reverse `TRUE` to run the scale high to low
        #' @param reset `TRUE` to return the column to the default scale first
        #' @returns The column styled, invisibly
        set_color_scale = function(column = NULL, preset = NULL, colors = NULL,
                                   reverse = NULL, reset = FALSE) {
            if (!is.null(column) && (!is.character(column) || length(column) != 1L))
                stop("[LensViewer] `column` must be one column name", call. = FALSE)
            if (!is.null(preset) && (!is.character(preset) || length(preset) != 1L))
                stop("[LensViewer] `preset` must be one preset name", call. = FALSE)
            if (!is.null(colors) && (!is.character(colors) || length(colors) < 2L ||
                    length(colors) > 9L))
                stop("[LensViewer] `colors` must be 2 to 9 colors", call. = FALSE)
            if (!is.null(reverse) && (!is.logical(reverse) || length(reverse) != 1L ||
                    is.na(reverse)))
                stop("[LensViewer] `reverse` must be TRUE or FALSE", call. = FALSE)
            if (!is.null(colors))
                colors <- lapply(unname(colors), function(cl)
                    as.list(as.integer(grDevices::col2rgb(cl)[, 1L])))
            r <- private$request("set_color_scale", list(column = column,
                preset = preset, colors = colors, reverse = reverse,
                reset = isTRUE(reset)))
            invisible(r$column)
        },

        #' @description Set the color, visibility and fill opacity of the
        #'   categories of a categorical metadata column. The viewer's legend
        #'   sets the same values. A category that is off is drawn like an
        #'   uncolored cell. Each argument is a vector named by category;
        #'   for `show` and `alpha` one unnamed value applies to every
        #'   category and named values override it, so
        #'   `alpha = c(0.2, Myeloid = 1)` draws Myeloid cells opaque and the
        #'   others at 20%. Centroids draw at twice the fill opacity, capped
        #'   at 1; the cells layer opacity (`set_layer("poly", alpha = )`)
        #'   applies on top.
        #' @param column Categorical column; `NULL` for the column cells are
        #'   colored by
        #' @param colors Named colors (names or hex strings)
        #' @param show Named logicals: color on or off
        #' @param alpha Named fill opacities in \[0, 1\]
        #' @param reset `TRUE` to return the column to its default colors
        #'   and opacity first
        #' @returns The column styled, invisibly
        style_categories = function(column = NULL, colors = NULL, show = NULL,
                                    alpha = NULL, reset = FALSE) {
            if (!is.null(column) && (!is.character(column) || length(column) != 1L))
                stop("[LensViewer] `column` must be one column name", call. = FALSE)
            split_all <- function(x, arg) {
                if (is.null(x)) return(list(all = NULL, named = NULL))
                nm <- names(x)
                if (is.null(nm)) nm <- rep("", length(x))
                if (sum(nm == "") > 1L)
                    stop("[LensViewer] `", arg, "` takes at most one unnamed value",
                        call. = FALSE)
                list(all = if (any(nm == "")) x[[which(nm == "")]],
                     named = x[nm != ""])
            }
            if (!is.null(show) && (!is.logical(show) || anyNA(show)))
                stop("[LensViewer] `show` must be TRUE/FALSE values", call. = FALSE)
            if (!is.null(alpha) && (!is.numeric(alpha) || anyNA(alpha) ||
                    any(alpha < 0 | alpha > 1)))
                stop("[LensViewer] `alpha` values must be in [0, 1]", call. = FALSE)
            if (!is.null(colors) && (!is.character(colors) || is.null(names(colors)) ||
                    any(names(colors) == "")))
                stop("[LensViewer] `colors` must be a character vector named by category",
                    call. = FALSE)
            sh <- split_all(show, "show")
            al <- split_all(alpha, "alpha")
            styles <- list()
            add <- function(labels, field, values) {
                for (k in seq_along(labels))
                    styles[[labels[[k]]]][[field]] <<- values[[k]]
            }
            if (length(colors)) add(names(colors), "color",
                lapply(colors, function(cl) as.list(as.integer(grDevices::col2rgb(cl)[, 1L]))))
            if (length(sh$named)) add(names(sh$named), "show", as.list(unname(sh$named)))
            if (length(al$named)) add(names(al$named), "alpha", as.list(as.numeric(al$named)))
            all <- list()
            if (!is.null(sh$all)) all$show <- sh$all
            if (!is.null(al$all)) all$alpha <- as.numeric(al$all)
            r <- private$request("set_category_style", list(
                column = column,
                all = if (length(all)) all,
                styles = if (length(styles)) styles else structure(list(), names = character()),
                reset = isTRUE(reset)))
            invisible(r$column)
        },

        #' @description Set the color, width and opacity of cell outlines;
        #'   `NULL` arguments leave a setting as is. Selected cells draw in the
        #'   selection color, 1 px wider. Outlines show once zoomed in far
        #'   enough to draw polygons. The "outlines" section of the cells panel
        #'   sets the same values.
        #' @param color Colour, as a name or hex string (`"#3d7dff"`)
        #' @param width Width in screen pixels, in \[0.01, 20\]
        #' @param alpha Opacity, in \[0, 1\]
        set_outline = function(color = NULL, width = NULL, alpha = NULL) {
            if (!is.null(color)) {
                if (!is.character(color) || length(color) != 1L)
                    stop("[LensViewer] `color` must be one color name or hex string",
                        call. = FALSE)
                color <- as.integer(grDevices::col2rgb(color)[, 1L])
            }
            if (!is.null(width) && (!is.numeric(width) || length(width) != 1L ||
                    is.na(width) || width < 0.01 || width > 20))
                stop("[LensViewer] `width` must be one number in [0.01, 20]", call. = FALSE)
            if (!is.null(alpha) && (!is.numeric(alpha) || length(alpha) != 1L ||
                    is.na(alpha) || alpha < 0 || alpha > 1))
                stop("[LensViewer] `alpha` must be one number in [0, 1]", call. = FALSE)
            private$request("set_outline", list(
                color = if (!is.null(color)) as.list(color),
                width = if (!is.null(width)) as.numeric(width),
                alpha = if (!is.null(alpha)) as.numeric(alpha)))
            invisible(self)
        },

        #' @description Show or hide an image, or set its colour or contrast;
        #'   `NULL` arguments leave a setting as is. Images draw under the
        #'   cells, each in its own colour, added together;
        #'   `set_layer("img", alpha = )` sets their opacity. RGB images
        #'   (`state()$config$images[[name]]$rgb`) draw in their own colours and
        #'   take only `show`.
        #' @param name Image name (see `describe()`)
        #' @param show Visibility
        #' @param color Colour, as a name or hex string (`"#3d7dff"`)
        #' @param contrast `c(low, high)`: pixel values shown as black and as
        #'   full colour
        set_image = function(name, show = NULL, color = NULL, contrast = NULL) {
            if (!is.character(name) || length(name) != 1L || !name %in% private$image_names)
                stop("[LensViewer] `name` must be one of the viewer's images: ",
                    if (length(private$image_names)) paste(private$image_names, collapse = ", ")
                    else "none", call. = FALSE)
            if (!is.null(color))
                color <- as.integer(grDevices::col2rgb(color)[, 1L])
            if (!is.null(contrast) && (!is.numeric(contrast) || length(contrast) != 2L))
                stop("[LensViewer] `contrast` must be c(low, high)", call. = FALSE)
            private$request("set_image", list(name = name, show = show,
                color = if (!is.null(color)) as.list(color),
                contrast = if (!is.null(contrast)) as.list(as.numeric(contrast))))
            invisible(self)
        },

        #' @description Register an image by landmarks in the viewer: opens
        #'   the landmark tool on `image`, shown in its own pane beside the
        #'   main view. Click a point in one pane, then the matching point in
        #'   the other; from three pairs on, the image is drawn with their
        #'   least-squares affine fit. The result is kept in `$registration`.
        #' @param image Name of the image to register; `NULL` keeps the one
        #'   being registered.
        #' @param reference Name of the image the matching points are placed
        #'   on, such as the DAPI image.
        #' @param alignment Starting placement: a 3 x 3 matrix from image
        #'   pixels to reference pixels, or a Xenium Explorer
        #'   `imagealignment.csv`.
        #' @param keypoints Landmark pairs to load: a data frame with `fixedX`,
        #'   `fixedY` (reference pixels), `alignmentX`, `alignmentY` (image
        #'   pixels), or a Xenium Explorer `keypoints.csv`. They replace the
        #'   current pairs.
        #' @param tool Open the landmark tool (default `TRUE`).
        register_image = function(image = NULL, reference = NULL, alignment = NULL,
                                  keypoints = NULL, tool = TRUE) {
            for (nm in c(image, reference))
                if (!is.character(nm) || length(nm) != 1L || !nm %in% private$image_names)
                    stop("[LensViewer] images must be among the viewer's images: ",
                        if (length(private$image_names)) paste(private$image_names, collapse = ", ")
                        else "none", call. = FALSE)
            if (is.null(image) && is.null(self$registration))
                stop("[LensViewer] no image is being registered; give `image`", call. = FALSE)
            if (!is.null(alignment)) alignment <- as.list(.affine_vector(.read_alignment(alignment)))
            if (!is.null(keypoints)) keypoints <- .read_keypoints(keypoints)
            msg <- list(image = image, reference = reference, alignment = alignment,
                landmarks = keypoints, mode = isTRUE(tool))
            r <- private$request("set_registration", msg[!vapply(msg, is.null, NA)])
            self$registration <- .parse_registration(r)
            invisible(self)
        },

        #' @description Discard the viewer's image registration
        clear_registration = function() {
            private$request("set_registration", list(reset = TRUE))
            self$registration <- NULL
            invisible(self)
        },

        #' @description The registered image as a giottoAffineImage: the image
        #'   file with `$registration`'s transform. Needs GiottoClass.
        #' @param name Name of the image; default the registered image's name
        registered_image = function(name = NULL) {
            reg <- self$registration
            .check_registration(reg)
            file <- private$image_files[[reg$image]]
            .registered_image(file, reg$transform, name %||% reg$image)
        },

        #' @description Add the registered image to a giotto object, replacing
        #'   an image of the same name.
        #' @param gobject A giotto object
        #' @param name Name of the image; default the registered image's name
        #' @return The giotto object with the image
        add_registered_image = function(gobject, name = NULL) {
            if (!inherits(gobject, "giotto"))
                stop("[LensViewer] `gobject` must be a giotto object", call. = FALSE)
            GiottoClass::setGiotto(gobject, self$registered_image(name), verbose = FALSE)
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
        #'   agent that cannot see the screen: where the cells come from and how
        #'   they are drawn, the view in data coordinates, layers, colouring, the
        #'   selection and its rules, and optionally what the selection holds in
        #'   one metadata column.
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
                cells = if (!is.null(private$cells)) list(
                    source = private$cells$source,
                    mark = .drawn_mark(private$cells, st$config$cellMark)),
                view = st$view, color_by = st$config$colorBy,
                layers = if (!is.null(st)) vapply(st$config$layers, function(l) isTRUE(l$show), NA),
                images = if (!is.null(st)) vapply(st$config$images, function(l) isTRUE(l$show), NA),
                panels = if (!is.null(st)) vapply(st$panels, function(p)
                    if (isTRUE(p$visible)) p$id else paste0(p$id, " (behind)"), ""),
                combine = private$combine,
                rules = vapply(private$rule_set, function(r) r$kind %||% "", ""),
                selected = length(self$selection),
                metadata = private$meta_names()
            )
            if (n && !is.null(st$view$bounds)) {
                b   <- unlist(st$view$bounds)
                ctx <- private$eval_ctx()
                out$in_view <- sum(ctx$x >= b[1L] & ctx$x <= b[2L] & ctx$y >= b[3L] & ctx$y <= b[4L])
            }
            if (!is.null(by)) {
                v <- private$meta_column(by)
                if (is.null(v))
                    stop("[LensViewer] no metadata column '", by, "'; pushed: ",
                        paste(private$meta_names(), collapse = ", "), call. = FALSE)
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
            private$need_object("LensViewer$subset")
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
            private$need_object("LensViewer$zoom_to")
            idx <- match(as.character(ids), private$cell_ids)
            idx <- idx[!is.na(idx)]
            if (!length(idx)) stop("[LensViewer] none of the IDs are cells in the viewer", call. = FALSE)
            ctx <- private$eval_ctx()
            x <- range(ctx$x[idx]); y <- range(ctx$y[idx])
            px <- max(diff(x), 1) * pad; py <- max(diff(y), 1) * pad
            invisible(self$set_view(bounds = c(x[1L] - px, x[2L] + px, y[1L] - py, y[2L] + py)))
        },

        #' @description Show a Vega-Lite chart as a docked panel, for example
        #'   from `GiottoVisuals::renderSpec(..., engine = "vegalite")`. Rows
        #'   with a `cell_ID` are linked to the viewer: they dim when not
        #'   selected, and an interval param named `brush` selects their cells
        #'   (selection source `panel:<id>`). Works before a browser connects,
        #'   and the panel comes back after a page reload.
        #' @param spec A Vega-Lite spec (list or JSON string) with inline
        #'   `data$values`, or a spec without data plus `data`
        #' @param data Optional data.frame for the spec (large data is sent as
        #'   a parquet file rather than inline)
        #' @param id Panel id. A panel already docked under this id is
        #'   replaced where it is; `NULL` makes a new one (`"panel-1"`, ...).
        #' @param title Tab title (default: the spec's title, else the id)
        #' @param where Where a new panel goes: `"tab"` (a tab next to `ref`),
        #'   or `"right"` / `"below"` (a split beside `ref`)
        #' @param ref Id of the panel to place it next to (see `panels()`);
        #'   `NULL` for the active chart, so that it joins the charts rather
        #'   than the controls
        #' @return The panel id, invisibly.
        push_panel = function(spec, data = NULL, id = NULL, title = NULL,
                              where = c("tab", "right", "below"), ref = NULL) {
            private$need_object("LensViewer$push_panel")
            where <- match.arg(where)
            if (is.null(id)) {
                repeat {
                    private$panel_seq <- private$panel_seq + 1L
                    id <- paste0("panel-", private$panel_seq)
                    if (is.null(private$pushed[[id]])) break
                }
            }
            .check_panel_id(id)
            if (!is.null(ref)) .check_panel_id(ref, "ref", builtin_ok = TRUE)
            if (is.character(spec)) spec <- jsonlite::fromJSON(spec, simplifyVector = FALSE)
            taken <- .spec_take_data(unclass(spec))
            spec  <- taken$spec
            rows  <- data %||% taken$rows
            payload <- list(id = id, title = title, where = where, ref = ref, spec = spec)
            private$drop_panel_file(id)
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
                    f <- sprintf("%s_%.0f.parquet", id, as.numeric(Sys.time()) * 1000)
                    arrow::write_parquet(rows, file.path(dir, f))
                    payload$data_url <- paste0("session/panels/", f)
                } else {
                    payload$spec$data <- list(values = rows)
                }
            }
            # Kept so a reload or a new tab gets it back (see `ready`)
            private$pushed[[id]] <- payload
            if (self$connected()) private$broadcast(.encode_ws_message("push_panel", payload))
            else message("[LensViewer] panel '", id, "' is shown when the viewer connects")
            invisible(id)
        },

        #' @description Close a docked panel: one pushed with `push_panel()`
        #'   or a built-in one (`"scatter"`, `"histogram"`, `"cells"`, ...).
        #'   The viewer's `+` menu adds built-in panels back; a closed control
        #'   (`"cells"`, `"layers"`, ...) stays closed after a page reload.
        #' @param id Panel id (see `panels()`)
        remove_panel = function(id) {
            .check_panel_id(id, builtin_ok = TRUE)
            private$drop_panel_file(id)
            private$pushed[[id]] <- NULL
            if (self$connected()) private$broadcast(.encode_ws_message("remove_panel", list(id = id)))
            invisible(self)
        },

        #' @description The docked panels: id, kind (a chart: `"scatter"`,
        #'   `"histogram"`, `"density"`, or `"spec"` for a pushed one; a
        #'   control: `"cells"`, `"transcripts"`, `"images"`, `"register"`,
        #'   `"annotations"`, `"layers"`), tab title, the group
        #'   of tabs it is in, and whether it is in view (not behind another
        #'   tab). With no browser connected, only the pushed panels R holds.
        #' @return A data frame.
        panels = function() {
            if (self$connected()) {
                p <- self$state()$panels
                return(data.frame(
                    id      = vapply(p, function(x) x$id, ""),
                    kind    = vapply(p, function(x) x$kind, ""),
                    title   = vapply(p, function(x) x$title, ""),
                    group   = vapply(p, function(x) as.character(x$group), ""),
                    visible = vapply(p, function(x) isTRUE(x$visible), NA),
                    stringsAsFactors = FALSE))
            }
            p <- private$pushed
            data.frame(
                id      = names(p) %||% character(),
                kind    = rep("spec", length(p)),
                title   = vapply(p, function(x) x$title %||% x$spec$title %||% x$id, ""),
                group   = rep(NA_character_, length(p)),
                visible = rep(NA, length(p)),
                stringsAsFactors = FALSE, row.names = NULL)
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
            private$need_object("LensViewer$push_polygons")
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
            cat("  object:      ", if (!private$loaded) "none" else
                sprintf("%s cells", format(length(private$cell_ids), big.mark = ",")), "\n")
            cat("  connected:   ", length(private$conns), "tab(s)\n")
            cat("  selection:   ", length(self$selection), "cell(s)\n")
            cat("  annotations: ", length(self$annotations), "polygon(s)\n")
            invisible(self)
        }
    ),

    private = list(
        token       = NULL,
        session     = NULL,
        transfer    = "auto",
        routes      = NULL,     # env: mounts (layer -> store dir), images (k -> file)
        loaded      = FALSE,    # whether an object is shown
        cells_file  = NULL,     # its cell table in the session dir (.export_session())
        load_seq    = 0L,       # loads so far; the manifest and each tab's ready carry it
        conn_load   = NULL,     # env: connection id -> the load its page came from
        image_names = character(),
        image_files = character(),  # image name -> the image's own file
        cell_ids    = NULL,
        cells       = NULL,     # source, launch mark and whether it is drawn
        spat_unit   = NULL,
        sel_seq     = 0L,
        server      = NULL,
        conns       = NULL,
        cbs         = list(),
        cached_meta = NULL,     # the load_metadata payload: columns, types, levels, files
        meta_values = list(),   # numbers behind numeric columns shown as categories
        col_types   = list(),

        meta_entry = function(name) {
            for (cl in private$cached_meta$columns) if (identical(cl$name, name)) return(cl)
            NULL
        },
        meta_names = function() vapply(private$cached_meta$columns, `[[`, "", "name"),
        # One column in cell order, read from the table; NULL if there is none
        meta_column = function(name) {
            entry <- private$meta_entry(name)
            if (is.null(entry)) return(NULL)
            .read_meta_column(private$meta_dir(), entry)
        },

        # The column files (one per column: the only copy of the metadata)
        meta_dir = function() file.path(private$session, "metadata"),
        # Adopt a payload (from .write_metadata(), or with a column rewritten
        # by .retype_meta()) and send it to every tab; `drop_rules_on` drops
        # rules on that column first. Files neither it nor the previous
        # payload points to are deleted.
        publish_meta = function(out, drop_rules_on = NULL) {
            if (!is.null(drop_rules_on) && length(private$rule_set)) {
                on_col <- vapply(private$rule_set, function(r)
                    identical(r$space, drop_rules_on), logical(1L))
                if (any(on_col)) {
                    for (src in names(private$rule_set)[on_col])
                        private$broadcast(private$rule_message(
                            list(source = src, rule = NULL, replace = FALSE)))
                    private$rule_set <- private$rule_set[!on_col]
                }
            }
            urls <- function(msg) vapply(msg$columns, `[[`, "", "url")
            .prune_meta_files(private$meta_dir(), c(urls(out$msg), urls(private$cached_meta)))
            private$cached_meta <- out$msg
            if (self$connected())
                private$broadcast(.encode_ws_message("load_metadata", out$msg))
            out$msg
        },
        rule_set    = list(),
        rule_seq    = 0L,       # rule changes sent to the page (set_rule `seq`)
        combine     = "or",
        config_json = NULL,     # the page's saved config, as it sent it (JSON text)
        pushed      = list(),   # push_panel() payloads by id, in push order
        panel_seq   = 0L,
        next_id     = 0L,
        req_id      = 0L,
        replies     = list(),
        log_entries = list(),

        cells_xy    = NULL,

        eval_ctx = function() {
            if (is.null(private$cells_xy)) {
                cells <- arrow::read_parquet(file.path(private$session, private$cells_file),
                    col_select = c("x", "y"))
                # As float32, exactly what the browser tests against
                private$cells_xy <- list(x = as.numeric(cells$x), y = as.numeric(cells$y))
            }
            c(private$cells_xy, list(meta = if (!is.null(private$cached_meta)) private$meta_column))
        },

        # Send a request to the first tab and wait for its reply
        request = function(type, data = NULL, timeout = 10) {
            private$need_object("LensViewer")
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

        drop_panel_file = function(id) {
            url <- private$pushed[[id]]$data_url
            if (!is.null(url)) unlink(file.path(private$session, sub("^session/", "", url)))
        },

        add_log = function(action, detail) {
            entry <- list(time = as.numeric(Sys.time()), action = action, detail = detail)
            private$log_entries <- utils::tail(c(private$log_entries, list(entry)), 200L)
        },

        # A set_rule message numbered so the page can say which rules its
        # selections reflect (`r_seq`); `bump`: a new change, not a re-send
        rule_message = function(data, bump = TRUE) {
            if (bump) private$rule_seq <- private$rule_seq + 1L
            .encode_ws_message("set_rule", c(data, list(seq = private$rule_seq)))
        },

        broadcast = function(json) {
            for (ws in as.list(private$conns)) try(ws$send(json), silent = TRUE)
        },

        # Show `object` (from .resolve_object()): write its manifest and cell
        # table, serve its stores and images, start its state empty, and make
        # open tabs reload. A tab still on the previous object is ignored until
        # it has (adr/0017).
        load = function(object) {
            imgs <- .image_entries(object$images, object$image_files)
            cells_file <- sprintf("cells-%d.parquet", private$load_seq + 1L)
            cl <- .export_session(object$layers$gpoints, object$layers$gpolygons,
                output = file.path(private$session, "manifest.json"),
                transfer = private$transfer, images = imgs$entries,
                locations = object$layers$locations, mark = object$mark,
                load = private$load_seq + 1L, cells_file = cells_file)
            old <- setdiff(list.files(private$session, "^cells-[0-9]+\\.parquet$"), cells_file)
            unlink(file.path(private$session, old))
            private$clear_object()
            private$set_routes(.layer_mounts(object$layers$gpoints, object$layers$gpolygons),
                imgs$files)
            private$cells_file  <- cells_file
            private$image_names <- vapply(imgs$entries, `[[`, "", "name")
            private$image_files <- imgs$sources
            private$cell_ids    <- cl$cell_ids
            private$cells       <- if (!is.null(cl$source)) cl[c("source", "mark", "marks")]
            private$spat_unit   <- object$spat_unit
            private$loaded      <- TRUE
            private$reload_tabs()
        },

        # No object: the page says so and waits
        load_empty = function() {
            .export_empty(file.path(private$session, "manifest.json"),
                load = private$load_seq + 1L)
            private$clear_object()
            private$set_routes(list(), list())
            private$image_names <- character()
            private$image_files <- character()
            private$cell_ids <- private$cells <- private$spat_unit <- private$cells_file <- NULL
            private$loaded <- FALSE
            private$reload_tabs()
        },

        # Drop what belonged to the object shown, with a warning naming the
        # work that is lost: nothing is kept for when it is shown again
        # (adr/0017). Keeping Lens work is a save's job.
        clear_object = function() {
            work <- if (private$loaded) private$lens_work()
            if (!is.null(work))
                warning("[LensViewer$set_object] the previous object's ", work,
                    " are not kept", call. = FALSE)
            for (id in names(private$pushed)) private$drop_panel_file(id)
            .prune_meta_files(private$meta_dir(), character())
            private$config_json  <- NULL
            private$rule_set     <- list()
            private$combine      <- "or"
            private$pushed       <- list()
            private$cached_meta  <- NULL
            private$meta_values  <- list()
            private$col_types    <- list()
            private$cells_xy     <- NULL
            self$annotations     <- list()
            self$registration    <- NULL
            self$selection       <- NULL
            self$selection_rules <- NULL
        },

        # The work done in the viewer on the object shown, as text ("2 rules,
        # 1 annotation"), or NULL for none. Settings are not counted.
        lens_work = function() {
            n <- c(rule = length(private$rule_set), annotation = length(self$annotations),
                `pushed panel` = length(private$pushed))
            parts <- sprintf("%d %s%s", n, names(n), ifelse(n == 1L, "", "s"))[n > 0L]
            if (!is.null(self$registration)) parts <- c(parts, "image registration")
            if (length(parts)) paste(parts, collapse = ", ")
        },

        # Serve `mounts` (layer -> store dir) and `images` (k -> file) instead
        # of the previous object's
        set_routes = function(mounts, images) {
            mounts <- lapply(mounts, normalizePath, mustWork = TRUE)
            images <- lapply(images, normalizePath, mustWork = TRUE)
            root <- .lens_root(private$token)
            for (m in names(private$routes$mounts))
                private$server$removeStaticPath(paste0(root, "/files/", m))
            paths <- .files_paths(root, mounts)
            if (length(paths)) private$server$setStaticPath(.list = paths)
            private$routes$mounts <- mounts
            private$routes$images <- images
        },

        # A new load: tabs reload, and until they do, what they send about
        # the previous object is ignored
        reload_tabs = function() {
            private$load_seq <- private$load_seq + 1L
            for (id in ls(private$conn_load)) assign(id, NA_integer_, envir = private$conn_load)
            if (self$connected()) private$broadcast(.encode_ws_message("reload"))
        },

        conn_id = function(ws) {
            for (id in ls(private$conns))
                if (identical(get(id, envir = private$conns), ws)) return(id)
            NULL
        },

        # Whether `ws`'s page shows the current load
        conn_current = function(ws) {
            id <- private$conn_id(ws)
            !is.null(id) && identical(private$conn_load[[id]], private$load_seq)
        },

        need_object = function(site) {
            if (!private$loaded)
                stop("[", site, "] no object loaded; call viewer$set_object(g) first",
                    call. = FALSE)
        },

        start_server = function(host) {
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
                    # A page still showing the previous object: what it says
                    # about that object would land on this one
                    if (parsed$type %in% .lens_object_types && !priv$conn_current(ws))
                        return(invisible())
                    switch(parsed$type,
                        # The tab has registered its handlers: send what it
                        # needs, so a reload or new tab matches the others
                        ready = {
                            if (!identical(as.integer(dat$protocol), .lens_protocol))
                                warning("[LensViewer] the viewer bundle speaks protocol ",
                                    .console_text(dat$protocol %||% "?"), ", this package ", .lens_protocol,
                                    "; reinstall GiottoLens or rebuild inst/viewer", call. = FALSE)
                            # The page loaded before the last set_object(): it
                            # reloads first. A page that does not say which
                            # load it has (an older bundle) is taken as current.
                            load <- dat$load
                            if (is.numeric(load) && length(load) == 1L &&
                                    as.integer(load) != priv$load_seq) {
                                ws$send(.encode_ws_message("reload"))
                                return(invisible())
                            }
                            id <- priv$conn_id(ws)
                            if (!is.null(id)) assign(id, priv$load_seq, envir = priv$conn_load)
                            # The saved config first, so a reload comes back as
                            # it was; then the data and panels it refers to
                            ws$send(.encode_ws_message("restore", list(
                                config = priv$config_json, panels = as.list(names(priv$pushed)))))
                            if (!is.null(priv$cached_meta))
                                ws$send(.encode_ws_message("load_metadata", priv$cached_meta))
                            # The rules carry R's rule count (`seq`); with
                            # none, the count alone, never a clear: the page
                            # may hold rules R has not heard of yet
                            if (length(priv$rule_set))
                                for (src in names(priv$rule_set))
                                    ws$send(priv$rule_message(list(source = src,
                                        rule = priv$rule_set[[src]], replace = FALSE,
                                        combine = priv$combine), bump = FALSE))
                            else ws$send(.encode_ws_message("rule_seq", list(seq = priv$rule_seq)))
                            for (p in priv$pushed)
                                ws$send(.encode_ws_message("push_panel", c(p, list(restore = TRUE))))
                        },
                        config = if (is.character(dat$json) && length(dat$json) == 1L)
                            priv$config_json <- dat$json,
                        panel_closed = if (is.character(dat$id) && length(dat$id) == 1L) {
                            priv$drop_panel_file(dat$id)
                            priv$pushed[[dat$id]] <- NULL
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
                        # "treat as" menu in the viewer
                        set_column_type = tryCatch({
                            pub$set_column_type(as.character(dat$column %||% ""),
                                as.character(dat$type %||% ""))
                            priv$add_log("set_column_type",
                                paste0(dat$column, " = ", dat$type))
                        }, error = function(e) {
                            priv$add_log("error", list(where = "set_column_type",
                                message = conditionMessage(e)))
                            warning("[LensViewer] ", .console_text(conditionMessage(e)),
                                call. = FALSE)
                        }),
                        {
                            # A selection the page made before it had R's
                            # latest rules: dropped, or it would undo them. The
                            # page sends another once it has them.
                            if (parsed$type == "cell_selection" && is.numeric(dat$r_seq) &&
                                    dat$r_seq < priv$rule_seq)
                                return(invisible())
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
                    id <- priv$conn_id(ws)
                    if (!is.null(id)) rm(list = id, envir = priv$conns)
                    if (!is.null(id) && exists(id, envir = priv$conn_load, inherits = FALSE))
                        rm(list = id, envir = priv$conn_load)
                }
            )
            private$server <- tryCatch(
                httpuv::startServer(host, self$port, .lens_app(
                    viewer_dir  = .viewer_dir(),
                    session_dir = private$session,
                    routes      = private$routes,
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
    line("cells", paste0(format(x$n_cells, big.mark = ","), if (!is.null(x$cells))
        sprintf(" from %s, drawn as %s",
            if (x$cells$source == "polygons") "polygons" else "spatial locations",
            .mark_text(x$cells$mark))))
    if (!is.null(x$view)) {
        b <- signif(unlist(x$view$bounds), 6)
        line("view", sprintf("x %s to %s, y %s to %s (zoom %.2f)", b[1], b[2], b[3], b[4], x$view$zoom))
        if (!is.null(x$in_view)) line("in view", paste(format(x$in_view, big.mark = ","), "cells"))
        line("layers", paste(names(x$layers)[x$layers], collapse = ", "))
        if (length(x$images))
            line("images", paste0(names(x$images), ifelse(x$images, "", " (off)"), collapse = ", "))
        if (length(x$panels)) line("panels", paste(x$panels, collapse = ", "))
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

# Panel ids name a dock slot, a selection source (`panel:<id>`) and a file:
# letters, digits, `_`, `.`, `-`. The built-in panels' ids (the kinds below,
# and scatter-2, ... for charts added in the viewer) are the viewer's, so
# push_panel() cannot take them. Keep in step with TYPES in panels/dock.ts.
.lens_builtin_panels <- c("scatter", "histogram", "density", "cells", "transcripts",
    "images", "register", "annotations", "layers")

.check_panel_id <- function(id, arg = "id", builtin_ok = FALSE) {
    if (!is.character(id) || length(id) != 1L || !grepl("^[A-Za-z0-9_.-]{1,64}$", id))
        stop("[LensViewer] `", arg, "` must be one string of letters, digits, '_', '.' or '-'",
            call. = FALSE)
    builtin <- paste0("^(", paste(.lens_builtin_panels, collapse = "|"), ")(-[0-9]+)?$")
    if (!builtin_ok && grepl(builtin, id))
        stop("[LensViewer] '", id, "' is a built-in panel; pick another id", call. = FALSE)
    invisible(id)
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

# The committed bundle, inst/viewer/, unless a local build in inst/viewer-dev/
# (`npm run build:dev`, never committed) is newer. A pull that updates the
# committed bundle makes it newer again, so a stale local build is not served.
.viewer_dir <- function(pkg = system.file(package = "GiottoLens")) {
    index <- file.path(pkg, c("viewer-dev", "viewer"), "index.html")
    found <- file.exists(index)
    if (!any(found))
        stop("[GiottoLens] cannot find the viewer bundle; reinstall GiottoLens ",
            "or run `npm run build:dev` in inst/viewer-src", call. = FALSE)
    if (all(found) && file.mtime(index[[1L]]) <= file.mtime(index[[2L]])) found[[1L]] <- FALSE
    dirname(index[found][[1L]])
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
