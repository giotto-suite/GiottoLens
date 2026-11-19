# ── launch_lens() ────────────────────────────────────────────────────────────

#' Launch the GiottoLens viewer
#'
#' Starts a combined HTTP + WebSocket server via httpuv and opens the viewer.
#' The viewer bundle and the GiottoDisk stores are served in place. The
#' manifest and cell table go to a per-viewer temp directory; the work done in
#' the viewer goes to its working bundle in the object's project, from which
#' `viewer$save()` makes a save (adr/0026).
#' Tile data goes through a Range-aware handler so the viewer reads only the
#' columns it draws.
#'
#' @param x          A giotto object in a GiottoDisk project, or `NULL`
#'   (default) to start without one and load it later with
#'   `viewer$set_object()`. An object not in a project needs `project`. What
#'   the viewer shows is a snapshot of the object: the one it matches, or a new
#'   one saved for it (see `LensViewer$set_object()`). A giottoPoints backed by
#'   a GiottoDisk tile store still works but is deprecated: pass a giotto
#'   object.
#' @param project    For an `x` not in a GiottoDisk project: the directory of
#'   the project to write it into (created if needed). Without `x`: a
#'   project to open on its start page, which lists its snapshots (see
#'   `LensViewer$open_project()`). Its points and polygons
#'   are written untiled and read as one tile, which the browser loads whole:
#'   up to 50,000 polygons and 2,000,000 points, or as set with
#'   `options(GiottoLens.untiled_max = c(polygons = , points = ))`. This is
#'   for small objects. Not allowed for an object already in a project.
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
#'   viewer first, which keeps its unsaved work as for `viewer$close()`.
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
    image_files = NULL,
    project    = NULL
) {
    transfer <- match.arg(transfer)
    # Checked before the server starts, so a bad argument leaves none running
    object <- if (!is.null(x) || !is.null(gpolygons)) .resolve_object(x,
        gpolygons = gpolygons, feat_type = feat_type, spat_unit = spat_unit,
        images = images, image_files = image_files, mark = mark, project = project)
    start <- if (is.null(object) && !is.null(project)) .project_source(project, "launch_lens")

    port <- if (is.null(port)) httpuv::randomPort(host = host) else as.integer(port)
    old  <- .lens_registry[[as.character(port)]]
    if (!is.null(old)) {
        message("[launch_lens] closing the viewer already on port ", port)
        old$close()
    }
    url_prefix <- sub("/+$", "", url_prefix %||% paste0("http://127.0.0.1:", port))

    viewer <- LensViewer$new(port = port, host = host, url_prefix = url_prefix,
        transfer = transfer, object = object, project = start)
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

# What launch_lens() and set_object() load, checked: the layers, images and
# mark, and for a giotto object `x` itself and the `project` to write it into
# (.check_project()). The load works out the layers and images again from the
# object as it is after the hand-over (adr/0018), since writing it into a
# project changes where its data is.
.resolve_object <- function(x, gpolygons = NULL, feat_type = "rna", spat_unit = "cell",
                            images = NULL, image_files = NULL, mark = NULL,
                            project = NULL) {
    giotto <- inherits(x, "giotto")
    if (!giotto) .warn_layer_launch()
    mark <- .check_mark(mark)
    if (giotto) .check_project(x, project)
    # An object still in memory has no stores to check until it is written
    layers <- .resolve_layers(x, gpolygons, feat_type, spat_unit,
        stores = !giotto || !is.null(x@source))
    imgs   <- .pick_images(x, images)
    list(
        x           = if (giotto) x,
        project     = project,
        layers      = layers,
        images      = imgs,
        pick_images = images,
        image_files = .check_image_files(image_files, taken = names(imgs)),
        mark        = mark,
        spat_unit   = if (giotto) spat_unit,
        feat_type   = if (giotto) feat_type
    )
}

# A giotto object is shown from a GiottoDisk project: its own, or `project`
# (a directory) when it is not in one yet. The project follows the object, so
# an object already in one cannot be given another.
.check_project <- function(x, project) {
    if (!is.null(x@source) && !is.null(project))
        stop("[launch_lens] x is already in a project (", x@source@path,
            "); `project` is for an object not in one", call. = FALSE)
    if (is.null(x@source) && is.null(project))
        stop("[launch_lens] x is not in a GiottoDisk project; pass `project`, ",
            "a directory, to write it into one", call. = FALSE)
    if (!is.null(project)) {
        if (!is.character(project) || length(project) != 1L || !nzchar(project))
            stop("[launch_lens] `project` must be a directory path", call. = FALSE)
        if (dir.exists(project) && !file.exists(file.path(project, "giottodir.json")) &&
                length(list.files(project, all.files = TRUE, no.. = TRUE)))
            stop("[launch_lens] `project` is a directory with other files and not a ",
                "GiottoDisk project: ", project, call. = FALSE)
    }
    if (!requireNamespace("GiottoDisk", quietly = TRUE))
        stop("[launch_lens] showing a giotto object needs GiottoDisk", call. = FALSE)
    invisible()
}

# Once per session: the tests and scripts that still do it see it once
.warn_layer_launch <- function() {
    if (isTRUE(.lens_warned$layers)) return(invisible())
    .lens_warned$layers <- TRUE
    warning("[launch_lens] launching from giottoPoints / giottoPolygon layers is ",
        "deprecated; pass a giotto object", call. = FALSE)
}
.lens_warned <- new.env(parent = emptyenv())

# Tags of the snapshots the object was last loaded from or saved as
# (GiottoClass's `@versions$snapshot`)
.snapshot_pointer <- function(x) {
    v <- x@versions
    if (is.list(v)) unlist(v$snapshot)
}

# A snapshot in `src` that holds `x` as it is: the ones it was loaded from or
# saved as first, then the latest others of the same object (objUID()). Equal
# means no change in their manifests, and nothing unfingerprinted that could
# have changed unseen. NULL if none.
.matching_snapshot <- function(src, x, tries = 5L) {
    info <- GiottoDisk::snapshotInfo(src)
    if (!nrow(info)) return(NULL)
    ptr  <- intersect(.snapshot_pointer(x), info$tag)
    same <- rev(info$tag[!is.na(info$object) & info$object %in% GiottoClass::objUID(x)])
    cand <- utils::head(unique(c(ptr, same)), tries)
    if (!length(cand)) return(NULL)
    m <- GiottoClass::objManifest(x)
    for (tag in cand) {
        f <- file.path(src@path, "giottosave", tag, "manifest.json")
        if (!file.exists(f)) next
        d <- GiottoClass::manifestDiff(GiottoClass::objManifest(f), m)
        if (!d$changed && !length(d$detail$unfingerprinted)) return(tag)
    }
    NULL
}

# A new name for a snapshot the viewer saves: lens_<date>_<time>, with _2, _3,
# ... if taken
.lens_snapshot_name <- function(src) {
    base  <- paste0("lens_", format(Sys.time(), "%Y%m%d_%H%M%S"))
    taken <- GiottoDisk::snapshotInfo(src, deleted = TRUE)$name
    name  <- base
    k <- 1L
    while (name %in% taken) {
        k <- k + 1L
        name <- sprintf("%s_%d", base, k)
    }
    name
}

# `stores`: whether to check that the layers are GiottoDisk stores
.resolve_layers <- function(x, gpolygons, feat_type, spat_unit, stores = TRUE) {
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
    if (stores) {
        .check_tile_store(gpoints, "giottoPoints", "points")
        .check_tile_store(gpolygons, "giottoPolygon", "polygons")
    }
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

# The most geometries the viewer reads from an untiled store, which it loads
# whole as one tile. Measured in headless Chrome (2026-11-12): 24-vertex
# polygons cost about 7 KB of JS heap each once drawn, held whatever the view
# (100k: 0.5 s, 700 MB; 250k: 1.2 s, 1.7 GB); points are thinned by zoom when
# decoded, so the file is the cost (46 MB per million points).
.lens_untiled_max <- c(polygons = 50000, points = 2000000)

# A layer the viewer can read: a GiottoDisk tile store, or an untiled
# geometry store, read as one tile (.store_tiles()) up to
# getOption("GiottoLens.untiled_max") geometries: a number, or named
# `polygons` and `points`
.check_tile_store <- function(obj, cls, what) {
    if (is.null(obj)) return(invisible())
    if (!inherits(obj, cls))
        stop(sprintf("[launch_lens] %s must be a %s, not %s",
            what, cls, class(obj)[[1L]]), call. = FALSE)
    sv <- obj@spatVector
    if (!inherits(sv, "parquetGeomStore")) {
        stop(sprintf(paste0("[launch_lens] %s are in memory (%s); GiottoLens ",
            "reads GiottoDisk stores. Pass `project` to write the object into ",
            "a project"), what, class(sv)[[1L]]),
            call. = FALSE)
    }
    if (!methods::.hasSlot(sv, "tiles")) {
        n <- .store_tiles(sv)$n
        max <- getOption("GiottoLens.untiled_max", .lens_untiled_max)
        if (!is.null(names(max)))
            max <- if (what %in% names(max)) max[[what]] else .lens_untiled_max[[what]]
        if (n > max)
            stop(sprintf(paste0("[launch_lens] %s are an untiled store of %s geometries; ",
                "GiottoLens reads untiled stores of up to %s (option GiottoLens.untiled_max). ",
                "Write them as a parquetGeomTileStore"), what, format(n, big.mark = ","),
                format(max, big.mark = ",")), call. = FALSE)
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
        #' @param project Without `object`: a project (gDirSource) whose start
        #'   page to show
        initialize = function(port, host, url_prefix, transfer = "auto", object = NULL,
                              project = NULL) {
            self$port         <- port
            private$transfer  <- transfer
            # Which viewer saved a snapshot; never the token, which grants access
            private$session_id <- .rand_id(16L)
            private$token     <- .rand_id(24L)
            private$conns     <- new.env(parent = emptyenv())
            private$conn_load <- new.env(parent = emptyenv())
            private$routes    <- new.env(parent = emptyenv())
            private$routes$mounts <- list()
            private$routes$images <- list()
            private$session   <- file.path(tempdir(), "giottolens",
                paste0(port, "-", .rand_id(8L)))
            dir.create(file.path(private$session, "items"), recursive = TRUE, showWarnings = FALSE)
            self$url <- paste0(url_prefix, .lens_root(private$token), "/")
            private$set_work()
            private$start_server(host)
            private$autosave()
            assign(as.character(port), self, envir = .lens_registry)
            tryCatch(if (is.null(object)) private$load_empty(project) else private$load(object),
                error = function(e) {
                    self$close()
                    stop(e)
                })
        },

        #' @description Show another object in this viewer. The server and its
        #'   URL stay; open tabs reload. Nothing of the current object is kept:
        #'   its settings, rules, annotations, pushed panels and metadata are
        #'   dropped. Returns before the tabs have reloaded.
        #'
        #'   The viewer shows a snapshot of the object, in the object's project:
        #'   the snapshot it was loaded from or saved as, or another of the same
        #'   object, when nothing has changed since ([GiottoClass::manifestDiff()]);
        #'   otherwise a new snapshot, `lens_<date>_<time>`, saved with
        #'   `creator = "GiottoLens"` and `keep = FALSE`. That save never moves
        #'   the object's data: an object with stores outside its project (disk
        #'   results not saved yet) is refused until saved with
        #'   `g <- saveGiotto(g)`. An object written into `project` is saved
        #'   with `keep = TRUE`.
        #' @param x,gpolygons,feat_type,spat_unit,images,image_files,mark,project
        #'   As in [launch_lens()]
        #' @param discard Whether to drop the current object's work not saved
        #'   (rules, annotations, regions, pushed panels, added images, an image
        #'   registration, an analysis). With any and `discard = FALSE`
        #'   (default), nothing changes and an error names them; save them
        #'   first with `save()`.
        set_object = function(x, gpolygons = NULL, feat_type = "rna", spat_unit = "cell",
                              images = NULL, image_files = NULL, mark = NULL,
                              project = NULL, discard = FALSE) {
            private$check_work("LensViewer$set_object", discard)
            private$load(.resolve_object(x, gpolygons = gpolygons, feat_type = feat_type,
                spat_unit = spat_unit, images = images, image_files = image_files,
                mark = mark, project = project))
            invisible(self)
        },

        #' @description The object shown, loaded from its snapshot with
        #'   [GiottoClass::loadGiotto()] on each call: the viewer does not hold
        #'   it. Changes made to it do not reach the viewer until passed to
        #'   `set_object()`.
        gobject = function() {
            private$need_object("LensViewer$gobject")
            if (is.null(private$snapshot))
                stop("[LensViewer$gobject] the viewer shows layers, not a giotto object",
                    call. = FALSE)
            private$load_snapshot(private$snapshot_name())
        },

        #' @description Show a snapshot of the current project, loaded with
        #'   [GiottoClass::loadGiotto()]. It is shown as it was saved: no new
        #'   snapshot is made for it.
        #' @param name Snapshot name, as listed by [GiottoDisk::snapshotInfo()]
        #' @param spat_unit,feat_type As in [launch_lens()]. Left out: the
        #'   current ones if the snapshot has them, else `"cell"` and `"rna"`,
        #'   else its first.
        #' @param discard As in `set_object()`
        checkout = function(name, spat_unit, feat_type, discard = FALSE) {
            if (is.null(private$project))
                stop("[LensViewer$checkout] no project open; call open_project() or ",
                    "set_object(g) first", call. = FALSE)
            private$check_work("LensViewer$checkout", discard)
            private$open_snapshot(private$project, name,
                spat_unit = if (missing(spat_unit)) NA else spat_unit,
                feat_type = if (missing(feat_type)) NA else feat_type,
                site = "LensViewer$checkout")
            invisible(self)
        },

        #' @description Open a GiottoDisk project. Without `name`, the viewer
        #'   shows the project's start page, which lists its snapshots, and
        #'   drops the object shown; with `name`, it shows that snapshot, as
        #'   `checkout()`. The project must exist: this never creates one.
        #' @param path The project's directory
        #' @param name Snapshot to show, or `NULL` (default) for the start page
        #' @param spat_unit,feat_type,discard As in `checkout()`
        open_project = function(path, name = NULL, spat_unit, feat_type, discard = FALSE) {
            private$check_work("LensViewer$open_project", discard)
            src <- .project_source(path, "LensViewer$open_project")
            if (is.null(name)) private$load_empty(project = src)
            else private$open_snapshot(src, name,
                spat_unit = if (missing(spat_unit)) NA else spat_unit,
                feat_type = if (missing(feat_type)) NA else feat_type,
                site = "LensViewer$open_project")
            invisible(self)
        },

        #' @description Save the work done in the viewer on the object shown:
        #'   rules, annotations, regions, pushed panels and metadata, column
        #'   types, added images, an image registration, comparisons and the
        #'   viewer's settings, with the snapshot shown, which is kept
        #'   (`keep = TRUE`). Written to `lens/<name>.<id>/` in the project
        #'   (adr/0026). An analysis is not saved yet. Open it again with
        #'   `open_save()`.
        #' @param name Save name: letters, digits, `_` and `-`
        #' @param description,labels Optional text and labels to find it by
        #' @param overwrite Whether to replace a save of the same name
        #' @returns The save's folder name, `<name>.<id>`, invisibly
        save = function(name, description = NULL, labels = NULL, overwrite = FALSE) {
            site <- "LensViewer$save"
            private$need_object(site)
            if (is.null(private$project))
                stop("[", site, "] the viewer shows layers, not an object in a project: ",
                    "there is nowhere to save", call. = FALSE)
            name <- .check_save_name(name, site)
            if (!is.null(description) && (!is.character(description) || length(description) != 1L))
                stop("[", site, "] `description` must be one string", call. = FALSE)
            if (!is.null(labels) && (!is.character(labels) || anyNA(labels)))
                stop("[", site, "] `labels` must be a character vector", call. = FALSE)
            old <- .lens_saves(private$project)
            old <- old[old$name == name, , drop = FALSE]
            if (nrow(old) && !isTRUE(overwrite))
                stop("[", site, "] a save named '", name, "' exists; pass `overwrite = TRUE` ",
                    "to replace it", call. = FALSE)
            snap <- private$snapshot_name()
            private$write_state(force = TRUE)
            id <- tolower(.rand_id(8L))
            tag <- paste0(name, ".", id)
            b <- private$bundle_info("save")
            b$created <- b$updated
            b$host <- b$pid <- NULL
            b$name <- name
            b$id <- id
            b$description <- description
            b$labels <- as.list(labels)
            dir <- file.path(.lens_dir(private$project), tag)
            .copy_bundle(private$work, dir, b)
            unlink(old$dir, recursive = TRUE)
            # What a save was made on is never pruned
            suppressMessages(GiottoDisk::snapshotMetadata(private$project, snap, keep = TRUE))
            private$saved_sig <- private$work_sig()
            private$saved_tag <- tag
            private$add_log("save", tag)
            message("[LensViewer] saved '", name, "' in ", dir)
            invisible(tag)
        },

        #' @description The saves of the project shown, newest first
        #' @param sessions Whether to list the working bundles of viewers that
        #'   ended with work not saved too (`kind = "session"`; `live` is
        #'   `TRUE` for a viewer still running, `NA` for one on another
        #'   machine)
        #' @returns A data.frame: `name` (what `open_save()` takes), `kind`,
        #'   `created`, `updated`, `snapshot` (the tag of the snapshot it was
        #'   made on), `description`, `labels`, `live`
        saves = function(sessions = FALSE) {
            if (is.null(private$project))
                stop("[LensViewer$saves] no project open", call. = FALSE)
            out <- .lens_saves(private$project, sessions = isTRUE(sessions))
            out[setdiff(names(out), "dir")]
        },

        #' @description Show a save of the project shown: its snapshot, then
        #'   its work. Rules that name cells by position are dropped if the
        #'   cells differ from those it was saved with. A working bundle left
        #'   by a viewer that ended (`saves(sessions = TRUE)`) is opened the
        #'   same way, and removed once this viewer has taken it over.
        #' @param name A save's name, as `saves()` lists it
        #' @param discard As in `set_object()`
        open_save = function(name, discard = FALSE) {
            site <- "LensViewer$open_save"
            if (is.null(private$project))
                stop("[", site, "] no project open; call open_project() first", call. = FALSE)
            private$open_save_in(private$project, name, discard, site)
            invisible(self)
        },

        #' @description Delete a save of the project shown. Its snapshot stays
        #'   kept.
        #' @param name A save's name, as `saves()` lists it
        delete_save = function(name) {
            site <- "LensViewer$delete_save"
            if (is.null(private$project))
                stop("[", site, "] no project open", call. = FALSE)
            hit <- .find_save(private$project, name, site)
            if (hit$kind == "session" && (identical(normalizePath(hit$dir), private$work) ||
                    isTRUE(hit$live)))
                stop("[", site, "] '", name, "' is the work of a viewer still running",
                    call. = FALSE)
            unlink(hit$dir, recursive = TRUE)
            if (identical(private$saved_tag, basename(hit$dir))) private$saved_tag <- NULL
            private$add_log("delete_save", name)
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
            out <- .write_metadata(meta, private$meta_dir(),
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
        #'   Integer and double columns are continuous by default. A text
        #'   column whose values are all numbers can be shown as continuous;
        #'   it is numeric from then on, so shown as categories again its
        #'   labels are the numbers. The
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
            if (!isTRUE(entry$numeric) && !(isTRUE(entry$number_text) && type == "continuous"))
                stop("[LensViewer] '", column, "' is not numeric; only numeric columns, ",
                    "and text columns whose values are all numbers, change type", call. = FALSE)
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

        #' @description What the object shown holds that `pull()` can add to
        #'   the viewer's metadata: one row per source and item, from the
        #'   cell metadata, expression matrices, spatial enrichments and dim
        #'   reductions of the spatial unit shown. Listed when the object is
        #'   loaded; the viewer's Data panel shows the same.
        #' @returns A data.frame with columns `source` (an id), `slot`,
        #'   `feat_type`, `name` (the matrix, enrichment or reduction; `NA`
        #'   for cell metadata), `item` and `key` (the item's key, which
        #'   `color_by()` takes).
        catalog = function() {
            .catalog_table(private$need_catalog("LensViewer$catalog"))
        },

        #' @description Add values from the object shown to the viewer's
        #'   metadata: one [GiottoClass::spatValues()] call, run as a job (see
        #'   `jobs()`) over the object the jobs' process holds. Pulled columns are
        #'   added to the metadata already shown, replacing a column of the
        #'   same name; they belong to the viewer, not to the object. The
        #'   viewer's Data panel pulls the same way.
        #'
        #'   An item pulled from two sources at once is named
        #'   `<source>_<item>`; dim reduction axes are named
        #'   `<reduction>_<axis>`, as `push_metadata()` names them.
        #' @param x Item names, each in one source only, or rows of
        #'   `catalog()`, with a `type` column if wanted
        #' @param types How the viewer treats each item: a named list or
        #'   vector, item -> `"categorical"` or `"continuous"` (see
        #'   `set_column_type()`). Left out, as the values are.
        #' @param wait Whether to wait for the pull to end. `FALSE` returns
        #'   at once with the job's id (for `cancel_job()`); the columns are
        #'   added when it ends.
        #' @returns The viewer, invisibly; with `wait = FALSE`, the job's id
        pull = function(x, types = NULL, wait = TRUE) {
            site <- "LensViewer$pull"
            items <- .pull_items(private$need_catalog(site), x, types)
            if (!isTRUE(wait)) return(invisible(private$pull_items(items, function(r)
                if (r$state == "error") warning("[", site, "] ", r$message, call. = FALSE))))
            out <- NULL
            private$pull_items(items, function(r) out <<- r)
            while (is.null(out)) later::run_now(0.05)
            if (out$state != "done") stop("[", site, "] ", out$message, call. = FALSE)
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

        #' @description Colour cells by a metadata column, or by one item of
        #'   the object shown (a gene, an enrichment or dim reduction column,
        #'   a cell metadata column of the object) without adding it to the
        #'   metadata. `NULL` for none.
        #' @param column A metadata column name; an item key (the `key`
        #'   column of `catalog()`); or one row of `catalog()`
        color_by = function(column = NULL) {
            site <- "LensViewer$color_by"
            if (is.data.frame(column)) {
                if (nrow(column) != 1L || !all(c("source", "item") %in% names(column)))
                    stop("[", site, "] `column` must be one row of catalog()", call. = FALSE)
                column <- .item_keys(private$need_catalog(site), column)
            }
            item <- if (.is_item_key(column)) private$read_item(column, site)
            private$request("set_color_by", Filter(Negate(is.null), list(column = column, item = item)))
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

        #' @description Set the color scale of a continuous metadata column
        #'   or of the gene, with the options of Giotto's plots
        #'   (`gradient_style`, `cell_color_gradient`, `gradient_midpoint`,
        #'   `gradient_limits`): a divergent scale centers its colors on a
        #'   midpoint (default the median), a sequential one runs them from the
        #'   low limit to the high one. Colors are a preset or custom ones,
        #'   spaced evenly; values beyond the limits take the end colors. The
        #'   default is Giotto's: divergent, `"blue-white-red"`; a sequential
        #'   scale without a preset is `"viridis"`. Every gene shares one scale.
        #'   The viewer's legend sets the same values. `NULL` arguments leave a
        #'   setting as is.
        #' @param column Continuous column, or `"@gene"` for the scale of the
        #'   gene of `color_by_gene()`; `NULL` for what cells are colored by
        #' @param preset Divergent: `"blue-white-red"`, `"RdBu"`, `"PuOr"`,
        #'   `"PRGn"`; sequential: `"viridis"`, `"magma"`, `"inferno"`,
        #'   `"plasma"`, `"cividis"`, `"turbo"`, `"gray"`, `"blue-red"`. Either
        #'   kind works with either style
        #' @param colors 2 to 9 colors (names or hex strings), low to high;
        #'   sets a custom scale
        #' @param reverse `TRUE` to run the scale high to low
        #' @param style `"divergent"` or `"sequential"`
        #' @param midpoint Value at the middle color of a divergent scale;
        #'   `NA` for the median
        #' @param limits `c(low, high)`; `NA` for the data range
        #' @param reset `TRUE` to return to the default scale first
        #' @returns The column styled, invisibly
        set_color_scale = function(column = NULL, preset = NULL, colors = NULL,
                                   reverse = NULL, style = NULL, midpoint = NULL,
                                   limits = NULL, reset = FALSE) {
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
            if (!is.null(style))
                style <- match.arg(style, c("divergent", "sequential"))
            if (!is.null(midpoint)) {
                if (length(midpoint) != 1L || !(is.na(midpoint) || is.numeric(midpoint)))
                    stop("[LensViewer] `midpoint` must be one number, or NA", call. = FALSE)
                midpoint <- if (is.na(midpoint)) "auto" else as.numeric(midpoint)
            }
            if (!is.null(limits)) {
                if (length(limits) == 1L && is.na(limits)) limits <- "auto"
                else if (!is.numeric(limits) || length(limits) != 2L || anyNA(limits) ||
                         limits[1L] >= limits[2L])
                    stop("[LensViewer] `limits` must be c(low, high) with low < high, or NA",
                        call. = FALSE)
                else limits <- as.list(as.numeric(limits))
            }
            if (!is.null(colors))
                colors <- lapply(unname(colors), function(cl)
                    as.list(as.integer(grDevices::col2rgb(cl)[, 1L])))
            r <- private$request("set_color_scale", list(column = column, style = style,
                preset = preset, colors = colors, reverse = reverse, midpoint = midpoint,
                limits = limits, reset = isTRUE(reset)))
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

        #' @description Set the color selected cells draw in, in the spatial
        #'   view (dots, and outlines once zoomed in) and in scatter panels.
        #'   Part of the saved config (`state()$config$selectionColor`).
        #' @param color Colour, as a name or hex string (`"#00e5ff"`);
        #'   `NULL` goes back to the `selection_color` preference (see
        #'   [lens_preferences()]), yellow unless set
        set_selection_color = function(color = NULL) {
            if (is.null(color)) {
                private$request("set_selection_color", list(reset = TRUE))
                return(invisible(self))
            }
            if (!is.character(color) || length(color) != 1L)
                stop("[LensViewer] `color` must be one color name or hex string",
                    call. = FALSE)
            color <- as.integer(grDevices::col2rgb(color)[, 1L])
            private$request("set_selection_color", list(color = as.list(color)))
            invisible(self)
        },

        #' @description Show the viewer's panels and controls dark or light.
        #'   The spatial view and scatter plots stay dark in both: their
        #'   colors (the selection, uncolored cells, image channels) are
        #'   chosen for a dark background. Part of the saved config
        #'   (`state()$config$theme`).
        #' @param theme `"dark"` (the default) or `"light"`
        set_theme = function(theme) {
            if (!is.character(theme) || length(theme) != 1L || !theme %in% c("dark", "light"))
                stop("[LensViewer] `theme` must be \"dark\" or \"light\"", call. = FALSE)
            private$request("set_theme", list(theme = theme))
            invisible(self)
        },

        #' @description Add an image file to the viewer. It is shown and
        #'   listed in the images and register panels, where it can be
        #'   registered by landmarks
        #'   (`register_image()`). Every connected tab opens it; tabs that
        #'   connect later, and reloads, open it too. It belongs to the
        #'   object shown and counts as Lens work for `set_object()`. The
        #'   "add image" button of the images panel opens a file dialog on
        #'   the machine R runs on and calls this with the chosen
        #'   file, after a choice of image type; option
        #'   `GiottoLens.choose_file` (a function returning a path) replaces
        #'   the dialog.
        #' @param file Path to a TIFF file the viewer can read by tile (see
        #'   [launch_lens()] `image_files`)
        #' @param name Image name; default the file name without its extension
        #' @param type `"if"` (immunofluorescence) or `"he"` (H&E): drawn
        #'   inside the data's extent. `"xenium"`: a 10x Xenium morphology
        #'   image, read with Giotto's Xenium reader
        #'   (`Giotto::importXenium()$load_image()`) and drawn in microns by
        #'   the pixel size in the Xenium output folder's `experiment.xenium`.
        #' @param timeout Seconds to wait for the viewer to open the image
        #' @return The viewer, invisibly.
        add_image = function(file, name = NULL, type = c("if", "he", "xenium"), timeout = 60) {
            type <- match.arg(type)
            private$need_object("LensViewer$add_image")
            if (!is.character(file) || length(file) != 1L || is.na(file))
                stop("[LensViewer] `file` must be one file path", call. = FALSE)
            if (!is.null(name) && (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name)))
                stop("[LensViewer] `name` must be one non-empty string", call. = FALSE)
            files <- .check_image_files(stats::setNames(file, name %||% ""),
                taken = private$image_names, caller = "LensViewer")
            if (!.is_tiff(files[[1L]]))
                stop("[LensViewer] '", file, "' is not a TIFF file", call. = FALSE)
            imgs <- if (type == "xenium")
                .image_entries(stats::setNames(list(.xenium_image_file(files[[1L]], names(files))),
                    names(files)), first = length(private$routes$images))
            else .image_entries(list(), files, first = length(private$routes$images))
            if (!length(imgs$entries))
                stop("[LensViewer] '", file, "' cannot be shown", call. = FALSE)
            entry <- imgs$entries[[1L]]
            k <- names(imgs$files)[[1L]]
            private$routes$images[[k]] <- normalizePath(imgs$files[[k]], mustWork = TRUE)
            if (self$connected()) {
                r <- tryCatch(private$request("add_image", list(entry = entry), timeout = timeout),
                    error = function(e) e)
                if (inherits(r, "error")) {
                    private$routes$images[[k]] <- NULL
                    stop("[LensViewer] the viewer could not open '", file, "': ",
                        sub("^\\[LensViewer\\] (add_image: )?", "", conditionMessage(r)), call. = FALSE)
                }
                json <- .encode_ws_message("add_image", list(entry = entry))
                for (ws in as.list(private$conns)[-1L]) try(ws$send(json), silent = TRUE)
            }
            private$image_names <- c(private$image_names, entry$name)
            private$image_files[[entry$name]] <- imgs$sources[[entry$name]]
            private$added_images <- c(private$added_images, list(entry))
            private$added_args[[entry$name]] <- list(file = file, name = entry$name, type = type)
            private$write_added_images()
            private$add_log("add_image", paste0(entry$name, " (", type, ") = ", imgs$sources[[entry$name]]))
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
            if (is.null(b))
                stop("[LensViewer$view_bounds] no spatial view is open", call. = FALSE)
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

        #' @description Save cells as a named region, for `compare_regions()`
        #'   and the viewer's Regions panel, whose "save selection" button
        #'   does the same. Regions belong to the object shown and count as
        #'   Lens work for `set_object()`.
        #' @param name Region name; a region of that name is replaced
        #' @param ids Cell IDs (default: the selection)
        #' @returns The region's cell IDs, invisibly
        save_region = function(name, ids = self$selection) {
            site <- "LensViewer$save_region"
            private$need_object(site)
            name <- .check_region_name(name, site)
            ids <- unique(as.character(ids))
            known <- ids %in% private$cell_ids
            if (!all(known))
                warning("[", site, "] ", sum(!known), " ID(s) are not cells in the viewer ",
                    "and were left out", call. = FALSE)
            ids <- ids[known]
            if (!length(ids))
                stop("[", site, "] no cells to save; select cells first", call. = FALSE)
            private$region_sets[[name]] <- ids
            private$region_md5[[name]] <- .strings_md5(ids)
            private$add_log("region", list(name = name, cells = length(ids)))
            private$send_regions(open = TRUE)
            invisible(ids)
        },

        #' @description The saved regions
        #' @param name A region name: return its cell IDs instead
        #' @returns A data.frame of region names and cell counts, or the cell
        #'   IDs of region `name`
        regions = function(name = NULL) {
            if (!is.null(name)) return(private$region_ids(name, "LensViewer$regions"))
            r <- private$region_sets
            data.frame(name = names(r) %||% character(), cells = vapply(r, length, 1L),
                row.names = NULL)
        },

        #' @description Remove a saved region
        #' @param name Region name
        remove_region = function(name) {
            private$region_ids(name, "LensViewer$remove_region")
            private$region_sets[[name]] <- NULL
            private$region_md5[[name]] <- NULL
            private$send_regions()
            invisible(self)
        },

        #' @description Select the cells of a saved region (selection source
        #'   `"r"`)
        #' @param name Region name
        select_region = function(name) {
            self$select(lens_cells(private$region_ids(name, "LensViewer$select_region")))
        },

        #' @description Differential expression between two saved regions, or
        #'   a region and every other cell, with [Giotto::findScranMarkers()].
        #'   Cells in both regions are left out. Runs as a job (see `jobs()`)
        #'   over the object the jobs' process holds. The result is docked as
        #'   a volcano plot (`DE: a vs b`); a click on a gene colours the cells
        #'   by it. The viewer's Regions panel runs the same comparison.
        #' @param a Region name
        #' @param b Region name; `NULL` for every cell not in `a`
        #' @param values Expression values (a name of the object's
        #'   expression); default `"normalized"`
        #' @param wait Whether to wait for the result. `FALSE` returns the
        #'   job's id at once; the table is then read with `de_results()`.
        #' @returns A data.frame, one row per gene in order of FDR: `gene`,
        #'   `logFC` (`a` vs `b`), `p_value`, `FDR`; with `wait = FALSE`, the
        #'   job's id, invisibly
        compare_regions = function(a, b = NULL, values = NULL, wait = TRUE) {
            site <- "LensViewer$compare_regions"
            out <- NULL
            id <- private$compare(a, b, values, site, function(r) out <<- r)
            if (!isTRUE(wait)) return(invisible(id))
            while (is.null(out)) later::run_now(0.05)
            if (out$state != "done") stop("[", site, "] ", out$message, call. = FALSE)
            private$de[[out$result]]$table
        },

        #' @description Results of `compare_regions()`
        #' @param id A result id (`"de-1"`, ...): return its table instead
        #' @returns A data.frame with one row per comparison: `id`, `a`, `b`,
        #'   cell counts, `values` and the number of genes at FDR < 0.05; or
        #'   the table of comparison `id`
        de_results = function(id = NULL) {
            if (!is.null(id)) {
                r <- private$de[[id]]
                if (is.null(r))
                    stop("[LensViewer$de_results] no result '", id, "'; results: ",
                        paste(names(private$de), collapse = ", "), call. = FALSE)
                return(r$table)
            }
            d <- private$de
            data.frame(id = names(d) %||% character(),
                a = vapply(d, `[[`, "", "a"), b = vapply(d, `[[`, "", "b"),
                cells_a = vapply(d, function(r) as.integer(r$cells_a), 1L),
                cells_b = vapply(d, function(r) as.integer(r$cells_b), 1L),
                values = vapply(d, `[[`, "", "values"),
                significant = vapply(d, function(r) sum(r$table$FDR < 0.05, na.rm = TRUE), 1L),
                row.names = NULL)
        },

        #' @description The analysis of the object shown (adr/0021): a
        #'   [LensAnalysis], made by the first call and kept until another
        #'   object is shown. The viewer's Analysis panel shows it, and opens
        #'   when it is made here; opening the panel from the viewer's "+" menu
        #'   makes it too. Nothing runs until a step is run or a parameter set.
        #'   Arguments given to a later call apply to the analysis there is.
        #' @param params Parameter values: a list by step of lists by
        #'   parameter, e.g. `list(filter = list(min_det_feats_per_cell = 20))`.
        #'   Menu parameters take one of their choices; number parameters
        #'   (thresholds, PCs, resolution, ...) any number in their range, typed
        #'   in the viewer the same way. Parameters left out take Giotto's
        #'   defaults; on GiottoDisk expression, z-score scaling and the
        #'   normalization methods other than `"standard"` are not offered.
        #' @param cell_markers Marker genes for the Automatic types step: a
        #'   named list (cell type -> genes), a data.frame with the cell type in
        #'   its first column and a gene in its second, or the path of such a
        #'   CSV file. Left out, the step is blocked until one is given.
        #' @param analyses Ids of the analyses to include besides
        #'   Preprocessing; see [LensAnalysis] `$catalog()`.
        #' @param settings A JSON file written by [LensAnalysis]
        #'   `$write_settings()`; its saved settings are listed in the viewer,
        #'   ready to restore.
        #' @param threads Threads for UMAP and data.table in the jobs' process,
        #'   for a new analysis. Default: preference `threads` (see
        #'   [lens_preferences()]), else 4.
        #' @param network_dir Folder where spatial networks are saved, for a
        #'   new analysis. A network is read from it when an analysis asks for
        #'   one with the same cells, cell coordinates and network settings, in
        #'   this or a later session. `NULL` keeps networks for the session
        #'   only. Default: option `GiottoLens.network_dir`, else preference
        #'   `network_dir` (see [lens_preferences()]), else `networks` in
        #'   [tools::R_user_dir()]'s cache folder for GiottoLens.
        #' @returns The [LensAnalysis]
        analysis = function(params = NULL, cell_markers = NULL, analyses = NULL, settings = NULL,
                            threads = .lens_pref("threads"), network_dir = .default_network_dir()) {
            a <- private$lens_analysis
            if (is.null(a)) {
                a <- private$start_analysis("LensViewer$analysis", params = params,
                    cell_markers = cell_markers, analyses = analyses %||% character(),
                    threads = threads, network_dir = network_dir)
                a$announce(open = TRUE)
            } else {
                for (s in names(params)) do.call(a$set, c(list(s), params[[s]]))
                if (!is.null(cell_markers)) a$cell_markers(cell_markers)
                for (id in setdiff(analyses, names(a$analyses()))) a$add(id)
            }
            if (!is.null(settings)) a$read_settings(settings)
            a
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
                    dir <- file.path(private$work, "panels")
                    dir.create(dir, showWarnings = FALSE)
                    f <- sprintf("%s_%.0f.parquet", id, as.numeric(Sys.time()) * 1000)
                    arrow::write_parquet(rows, file.path(dir, f))
                    payload$data_url <- paste0("work/panels/", f)
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

        #' @description Jobs running in the viewer's background R process
        #'   (adr/0025), one row each. The process starts with the first job,
        #'   which waits while it loads its packages and the object shown, and
        #'   stops with the viewer; later jobs on the same object start at once.
        #' @returns A data.frame with columns `id`, `label`, `started`, and
        #'   `done` and `total` (progress; `NA` for a job that reports none)
        jobs = function() {
            js <- unname(as.list(private$running_jobs))
            num <- function(f) vapply(js, function(j) as.numeric(j$progress[[f]] %||% NA), 0)
            data.frame(id = vapply(js, function(j) j$id, 0L),
                label = vapply(js, function(j) j$label, ""),
                started = .POSIXct(vapply(js, function(j) as.numeric(j$started), 0)),
                done = num("done"), total = num("total"), row.names = NULL)
        },

        #' @description Cancel a job. One not started yet is dropped; one
        #'   running is interrupted (compiled code may finish its current call
        #'   first). Its result is never applied.
        #' @param id Job id, as `jobs()` lists it
        #' @returns Whether the job was cancelled, invisibly
        cancel_job = function(id) invisible(private$cancel(id)),

        #' @description Stop the server and remove this viewer's temp files.
        #'   The power button next to R's connection in the viewer does the
        #'   same; open tabs say the viewer is stopped. Work not saved stays in
        #'   the project, as its working bundle, which `open_save()` opens
        #'   again (`saves(sessions = TRUE)` lists it).
        #' @param discard Whether to delete work not saved instead
        close = function(discard = FALSE) {
            if (!isTRUE(discard) && !isFALSE(discard))
                stop("[LensViewer$close] `discard` must be TRUE or FALSE", call. = FALSE)
            # An analysis alone is not in the working bundle: nothing to keep
            unsaved <- if (!is.null(private$server) && !is.null(private$project) &&
                    private$loaded && private$work_changed()) private$lens_work()
            if (!is.null(unsaved) && !discard) private$write_state(force = TRUE)
            private$stop_jobs()
            private$close_analysis()
            if (!is.null(private$server)) {
                # Tabs stop trying to reconnect and say the viewer is stopped
                if (self$connected()) {
                    private$broadcast(.encode_ws_message("closed"))
                    later::run_now(0.05)
                }
                private$server$stop()
                private$server <- NULL
                rm(list = ls(private$conns), envir = private$conns)
                unlink(private$session, recursive = TRUE)
                if (!is.null(unsaved) && !discard) {
                    message("[LensViewer] work not saved (", unsaved, ") is kept in ",
                        private$work, "; open it again with open_save(\"",
                        basename(private$work), "\")")
                } else if (!is.null(private$work)) unlink(private$work, recursive = TRUE)
                private$work <- NULL
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
            if (!is.null(private$project))
                cat("  project:     ", private$project@path, "\n")
            if (!is.null(private$snapshot))
                cat("  snapshot:    ", private$snapshot, "\n")
            if (!is.null(private$saved_tag))
                cat("  save:        ", private$saved_tag, "\n")
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
        session_id  = NULL,     # recorded on the snapshots this viewer saves
        project     = NULL,     # gDirSource of the object shown
        snapshot    = NULL,     # tag of the snapshot shown
        feat_type   = NULL,
        cells_file  = NULL,     # its cell table in the session dir (.export_session())
        load_seq    = 0L,       # loads so far; the manifest and each tab's ready carry it
        conn_load   = NULL,     # env: connection id -> the load its page came from
        image_names = character(),
        image_files = character(),  # image name -> the image's own file
        added_images = list(),      # manifest entries of add_image(), in order
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
        catalog_data = NULL,    # what the object shown can pull (.lens_catalog())
        # ── Its analysis (R/analysis.R) ──
        lens_analysis = NULL,
        owned = list(),         # metadata columns by owner (the analysis), own_columns()

        start_analysis = function(site, ...) {
            cat <- private$need_catalog(site)
            if (!requireNamespace("Giotto", quietly = TRUE))
                stop("[", site, "] an analysis needs the Giotto package", call. = FALSE)
            expr <- Filter(function(s) s$slot == "expression", cat$sources)
            ft <- private$feat_type %||% if (length(expr)) expr[[1L]]$feat_type else "rna"
            private$lens_analysis <- LensAnalysis$new(self, self$gobject(),
                host = private$analysis_host(), spat_unit = cat$spat_unit, feat_type = ft, ...)
            private$lens_analysis
        },
        # What the analysis is given of the viewer
        analysis_host = function() list(
            root = paste0("snapshot:", private$snapshot),
            start_job = function(label, fun, args, progress = FALSE, on_end = NULL)
                private$start_job(label, fun, args, progress = progress, on_end = on_end),
            cancel = function(id, why) private$cancel(id, why),
            progress_file = function(id) private$running_jobs[[as.character(id)]]$file %||% NA_character_,
            columns = function(df) private$own_columns("analysis", df),
            color_item = function(key, done) private$color_item(key, done)),
        close_analysis = function() {
            a <- private$lens_analysis
            private$lens_analysis <- NULL
            if (!is.null(a)) a$close()
        },
        # A message for the analysis from a tab: `analysis_open` makes one
        analysis_message = function(ws, type, dat) tryCatch({
            if (identical(type, "analysis_open")) {
                if (is.null(private$lens_analysis)) private$start_analysis("LensViewer")
                private$lens_analysis$announce()
            } else if (!is.null(private$lens_analysis)) private$lens_analysis$handle(type, dat)
        }, error = function(e) {
            private$add_log("error", list(where = type, message = conditionMessage(e)))
            warning("[LensViewer] ", .console_text(conditionMessage(e)), call. = FALSE)
        }),
        # The metadata columns `owner` keeps in the metadata shown, beside
        # those pushed and pulled: `df` (cell_ID and its columns now) replaces
        # its previous set, and rules on columns it no longer has are dropped
        own_columns = function(owner, df) {
            cols <- setdiff(names(df), "cell_ID")
            gone <- setdiff(private$owned[[owner]] %||% character(), cols)
            msg <- private$cached_meta %||% list(n = length(private$cell_ids), columns = list())
            if (length(gone)) msg$columns <- Filter(function(cl) !cl$name %in% gone, msg$columns)
            if (length(cols)) {
                out <- .write_metadata(df, private$meta_dir(), private$cell_ids,
                    types = unlist(private$col_types), site = "LensViewer")
                private$col_types[out$dropped] <- NULL
                for (cn in names(out$values)) private$meta_values[cn] <- list(out$values[[cn]])
                msg <- .merge_meta(msg, out$msg)
            }
            private$meta_values[gone] <- NULL
            private$owned[[owner]] <- cols
            private$publish_meta(list(msg = msg), drop_rules_on = gone)
            invisible(cols)
        },
        # Colour every tab's cells by item `key` once it is read; `done(r)`
        # gets the read's answer
        color_item = function(key, done = NULL) {
            private$need_item(key, "LensViewer", function(r) {
                if (is.null(r$error) && self$connected())
                    private$broadcast(.encode_ws_message("set_color_by",
                        list(column = key, item = r$data)))
                if (!is.null(done)) done(r)
            })
        },
        # ── Regions and their comparisons (R/regions.R) ──
        region_sets = list(),   # region name -> cell IDs
        de          = list(),   # compare_regions() results by id
        de_seq      = 0L,

        region_ids = function(name, site) {
            if (!is.character(name) || length(name) != 1L || is.null(private$region_sets[[name]]))
                stop("[", site, "] no region '", paste(name, collapse = ", "), "'; regions: ",
                    if (length(private$region_sets)) paste(names(private$region_sets),
                        collapse = ", ") else "none (save one with save_region())",
                    call. = FALSE)
            private$region_sets[[name]]
        },
        regions_msg = function(open = FALSE) {
            list(regions = unname(lapply(names(private$region_sets), function(n)
                list(name = n, n = length(private$region_sets[[n]])))), open = open)
        },
        send_regions = function(open = FALSE) {
            if (self$connected())
                private$broadcast(.encode_ws_message("regions", private$regions_msg(open)))
        },
        # Start a comparison job; `done` gets its end, with the result's id.
        # Returns the job's id.
        compare = function(a, b, values, site, done, ref = NULL) {
            if (!requireNamespace("Giotto", quietly = TRUE))
                stop("[", site, "] comparing regions needs the Giotto package", call. = FALSE)
            ids_a <- private$region_ids(a, site)
            ids_b <- if (!is.null(b)) private$region_ids(b, site)
            if (identical(a, b)) stop("[", site, "] `a` and `b` are the same region", call. = FALSE)
            src <- .de_source(private$need_catalog(site), values, private$feat_type, site)
            b_label <- b %||% "rest"
            what <- sprintf("%s vs %s", a, b_label)
            private$start_job(paste("DE", what), .region_de, list(a = ids_a, b = ids_b,
                values = src$name, spat_unit = private$catalog_data$spat_unit,
                feat_type = src$feat_type), ref = ref, on_end = done,
                apply = function(r) {
                    tab <- r$table[order(r$table$FDR, -abs(r$table$logFC)), , drop = FALSE]
                    rownames(tab) <- NULL
                    private$de_seq <- private$de_seq + 1L
                    id <- paste0("de-", private$de_seq)
                    private$de[[id]] <- list(a = a, b = b_label, cells_a = r$n_a,
                        cells_b = r$n_b, cells_both = r$n_both, values = src$name,
                        feat_type = src$feat_type, table = tab)
                    v <- .de_volcano(tab, a, b_label)
                    suppressMessages(self$push_panel(v$spec, data = v$data, id = id,
                        title = paste0("DE: ", what,
                            if (!identical(src$name, "normalized")) paste0(" (", src$name, ")"))))
                    message(sprintf("[LensViewer] %s: %s and %s cells, %d gene(s) at FDR < 0.05%s",
                        what, format(r$n_a, big.mark = ","), format(r$n_b, big.mark = ","),
                        sum(tab$FDR < 0.05, na.rm = TRUE),
                        if (r$n_both) sprintf(" (%d cell(s) in both left out)", r$n_both) else ""))
                    id
                })
        },
        # A click on a gene in a volcano plot (`panel_pick`): colour that
        # page's cells by it, once its item is read
        pick_gene = function(ws, id, gene) {
            de <- private$de[[id]]
            if (is.null(de) || !is.character(gene) || length(gene) != 1L || !nzchar(gene)) return()
            key <- .item_key("expression", de$feat_type, gene, name = de$values)
            private$need_item(key, "LensViewer", function(r) {
                if (!is.null(r$error)) return(private$add_log("error",
                    list(where = "panel_pick", message = r$error)))
                try(ws$send(.encode_ws_message("set_color_by", list(column = key, item = r$data))),
                    silent = TRUE)
            })
        },

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
        need_catalog = function(site) {
            private$need_object(site)
            if (is.null(private$catalog_data))
                stop("[", site, "] the viewer shows layers, not a giotto object: ",
                    "there is nothing to pull from", call. = FALSE)
            private$catalog_data
        },
        # Pull `items` (from .pull_items()) with one spatValues() call, in a
        # job, and add them to the metadata shown. `done` gets the job's end
        # (R/jobs.R), its result the columns added. Returns the job's id.
        pull_items = function(items, done, ref = NULL) {
            plan <- .pull_plan(private$catalog_data, items)
            n <- nrow(plan$cols)
            private$start_job(paste("pull", n, if (n == 1L) "item" else "items"), .plan_values,
                list(keys = plan$keys), apply = function(vals) private$add_pulled(vals, plan),
                ref = ref, on_end = done)
        },
        add_pulled = function(vals, plan) {
            site <- "LensViewer$pull"
            got <- plan$cols$result %in% names(vals)
            if (!all(got))
                warning("[", site, "] not found in the object: ",
                    paste(plan$cols$result[!got], collapse = ", "), call. = FALSE)
            cols <- plan$cols[got, , drop = FALSE]
            if (!nrow(cols)) stop("[", site, "] nothing was pulled", call. = FALSE)
            vals <- vals[c("cell_ID", cols$result)]
            names(vals) <- c("cell_ID", cols$column)
            # A type given here applies over one kept from set_column_type()
            given <- stats::setNames(cols$type, cols$column)
            types <- c(unlist(private$col_types), given[!is.na(given)])
            types <- types[!duplicated(names(types), fromLast = TRUE)]
            out <- .write_metadata(vals, private$meta_dir(), private$cell_ids,
                types = types, site = site)
            rm(vals)
            added <- vapply(out$msg$columns, `[[`, "", "name")
            replaced <- intersect(added, private$meta_names())
            private$col_types[out$dropped] <- NULL
            for (cn in added) private$meta_values[cn] <- list(out$values[[cn]])
            private$publish_meta(list(msg = .merge_meta(private$cached_meta, out$msg)),
                drop_rules_on = replaced)
            private$add_log("pull", paste(added, collapse = ", "))
            message("[LensViewer] pulled ", length(added), " column(s): ",
                paste(added, collapse = ", "))
            added
        },

        # The column files (one per column: the only copy of the metadata), in
        # the working bundle
        meta_dir = function() file.path(private$work, "metadata"),
        # Items read on their own (color_by() an item, the `item` ask): one
        # file each, kept for the object shown; their entries by item key
        items_dir = function() file.path(private$session, "items"),
        item_files = list(),
        item_reads = list(),    # by key: the job reading it and who waits for it
        # An item's file entry for `done()` as list(data =) or list(error =):
        # at once if it was read, else once a job has read it. A second ask
        # for an item being read waits for the same job.
        need_item = function(key, site, done) {
            hit <- private$item_files[[key]]
            if (!is.null(hit)) return(done(list(data = hit)))
            if (!is.null(private$item_reads[[key]])) {
                private$item_reads[[key]]$waits <- c(private$item_reads[[key]]$waits, done)
                return(invisible())
            }
            cat <- private$need_catalog(site)
            ref <- .parse_item_key(key, site)
            # An analysis's item names the step result it is read from
            # (adr/0021); others, a catalog source of the snapshot shown
            if (startsWith(ref$method %||% "", "analysis:")) {
                job <- if (!is.null(private$lens_analysis)) private$lens_analysis$item_job(key)
                if (is.null(job))
                    stop("[", site, "] '", key, "' is not an item of the analysis", call. = FALSE)
                res <- "item"
            } else {
                src <- .catalog_source_for(cat, ref, site)
                plan <- .pull_plan(cat, data.frame(source = src$id, item = ref$item,
                    type = NA_character_))
                res <- plan$cols$result
                job <- list(label = paste("read", ref$item), fun = .plan_values,
                    args = list(keys = plan$keys))
            }
            id <- private$start_job(job$label, job$fun, job$args,
                apply = function(vals) {
                    if (!res %in% names(vals))
                        stop("'", ref$item, "' was not found in the object", call. = FALSE)
                    out <- .write_metadata(data.frame(cell_ID = vals$cell_ID, item = vals[[res]]),
                        private$items_dir(), private$cell_ids, site = site, served = "session/items")
                    entry <- out$msg$columns[[1L]]
                    entry$name <- key
                    private$item_files[[key]] <- entry
                    entry
                },
                on_end = function(r) {
                    read <- private$item_reads[[key]]
                    if (!identical(read$job, id)) return()
                    private$item_reads[[key]] <- NULL
                    ans <- .job_answer(r)
                    for (w in read$waits) w(ans)
                })
            private$item_reads[[key]] <- list(job = id, waits = list(done))
            invisible()
        },
        # need_item() for R, waiting
        read_item = function(key, site) {
            out <- NULL
            private$need_item(key, site, function(r) out <<- r)
            while (is.null(out)) later::run_now(0.05)
            if (!is.null(out$error)) stop("[", site, "] ", out$error, call. = FALSE)
            out$data
        },
        # Adopt a payload (from .write_metadata(), or with a column rewritten
        # by .retype_meta()) and send it to every tab; `drop_rules_on` drops
        # rules on those columns first. Files neither it nor the previous
        # payload points to are deleted.
        publish_meta = function(out, drop_rules_on = NULL) {
            if (!is.null(drop_rules_on) && length(private$rule_set)) {
                on_col <- vapply(private$rule_set, function(r)
                    isTRUE(r$space %in% drop_rules_on), logical(1L))
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
        combine     = "and",    # cross-filter by default, as the page
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

        # session/images_added.json: the images added after launch, opened
        # by the viewer after the manifest's
        write_added_images = function() {
            jsonlite::write_json(private$added_images,
                file.path(private$session, "images_added.json"),
                auto_unbox = TRUE, digits = NA, null = "null")
        },

        # The "add image" button: a file dialog, then add_image(). Errors go
        # to the tab that asked.
        choose_image = function(ws, type = "if") {
            r <- tryCatch({
                type <- match.arg(type, c("if", "he", "xenium"))
                file <- .choose_image_file()
                if (is.null(file)) list(cancelled = TRUE)
                else {
                    self$add_image(file, type = type)
                    list(added = utils::tail(private$image_names, 1L))
                }
            }, error = function(e) {
                private$add_log("error", list(where = "add_image", message = conditionMessage(e)))
                warning(.console_text(conditionMessage(e)), call. = FALSE)
                list(error = sub("^\\[LensViewer\\] ", "", conditionMessage(e)))
            })
            try(ws$send(.encode_ws_message("add_image_result", r)), silent = TRUE)
        },

        drop_panel_file = function(id) {
            url <- private$pushed[[id]]$data_url
            if (!is.null(url)) unlink(file.path(private$work, sub("^work/", "", url)))
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
            if (!is.null(object$x)) object <- private$handover(object)
            # Their results would land on the next object; the daemon keeps
            # the old object until a job asks for another
            for (id in names(private$running_jobs)) private$cancel(id, "the object shown changed")
            catalog <- if (!is.null(object$x)) .lens_catalog(object$x, object$spat_unit)
            imgs <- .image_entries(object$images, object$image_files)
            cells_file <- sprintf("cells-%d.parquet", private$load_seq + 1L)
            cl <- .export_session(object$layers$gpoints, object$layers$gpolygons,
                output = file.path(private$session, "manifest.json"),
                transfer = private$transfer, images = imgs$entries,
                locations = object$layers$locations, mark = object$mark,
                load = private$load_seq + 1L, cells_file = cells_file,
                catalog = !is.null(catalog))
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
            private$feat_type   <- object$feat_type
            private$catalog_data <- catalog
            private$loaded      <- TRUE
            private$set_work()
            if (!is.null(private$project)) .add_recent(private$project@path)
            private$reload_tabs()
        },

        # No object: the page says so and waits, or with `project` (a
        # gDirSource) lists its snapshots to open (adr/0019)
        load_empty = function(project = NULL) {
            .export_empty(file.path(private$session, "manifest.json"),
                load = private$load_seq + 1L, project = if (!is.null(project)) project@path)
            private$clear_object()
            private$set_routes(list(), list())
            private$image_names <- character()
            private$image_files <- character()
            private$cell_ids <- private$cells <- private$spat_unit <- private$cells_file <- NULL
            private$feat_type <- private$snapshot <- NULL
            private$project <- project
            private$loaded <- FALSE
            private$set_work()
            if (!is.null(project)) .add_recent(project@path)
            private$reload_tabs()
        },

        # The snapshot to show for giotto object `object$x` (adr/0018): one it
        # matches, or a new one. Stops before saving anything when the save
        # would move the object's data. Returns `object` with the layers and
        # images of the object as saved. An object just loaded from a
        # snapshot (`object$snapshot`, its tag) is shown from it unchecked.
        handover = function(object) {
            x <- object$x
            if (!is.null(object$snapshot)) {
                src <- x@source
                tag <- object$snapshot
            } else if (is.null(x@source)) {
                src <- suppressMessages(GiottoDisk::gDirSource(object$project))
                x <- suppressMessages(GiottoDisk::sourceWrite(src, x))
                x <- private$save_snapshot(src, x, keep = TRUE)
                tag <- .snapshot_pointer(x)
            } else {
                src <- x@source
                tag <- .matching_snapshot(src, x)
                if (is.null(tag)) {
                    inside <- GiottoDisk::sourceContains(src, x)
                    if (!isTRUE(inside))
                        stop("[LensViewer] the object has data on disk that is not saved in its ",
                            "project (", paste(attr(inside, "external"), collapse = ", "),
                            "); save it first with g <- saveGiotto(g)", call. = FALSE)
                    x <- private$save_snapshot(src, x, keep = FALSE)
                    tag <- .snapshot_pointer(x)
                }
            }
            object$layers <- .resolve_layers(x, NULL, object$feat_type, object$spat_unit)
            object$images <- .pick_images(x, object$pick_images)
            private$project  <- src
            private$snapshot <- tag
            object
        },

        # Through loadGiotto(), which finishes what snapshotLoad() reads:
        # project migration, images, python path, data.table allocation and
        # initialize()
        load_snapshot = function(name, path = private$project@path) {
            suppressMessages(GiottoClass::loadGiotto(path, name = name, verbose = FALSE))
        },

        # Show snapshot `name` of project `src`. NA spat_unit / feat_type: the
        # current ones if it has them, else .default_keys()'s.
        open_snapshot = function(src, name, spat_unit = NA, feat_type = NA, site) {
            if (!is.character(name) || length(name) != 1L || is.na(name))
                stop("[", site, "] `name` must be a snapshot name", call. = FALSE)
            info <- GiottoDisk::snapshotInfo(src)
            tag <- info$tag[info$name == name]
            if (!length(tag))
                stop("[", site, "] no snapshot '", name, "' in ", src@path, "; it has: ",
                    if (nrow(info)) paste(info$name, collapse = ", ") else "none",
                    call. = FALSE)
            x <- private$load_snapshot(name, src@path)
            keys <- .default_keys(x, spat_unit, feat_type,
                prefer_unit = private$spat_unit, prefer_feat = private$feat_type)
            object <- .resolve_object(x, spat_unit = keys$spat_unit,
                feat_type = keys$feat_type)
            object$snapshot <- tag
            private$load(object)
        },

        # Stops when the object shown has Lens work and `discard` is FALSE:
        # what set_object(), checkout() and open_project() will not drop
        check_work = function(site, discard) {
            if (!isTRUE(discard) && !isFALSE(discard))
                stop("[", site, "] `discard` must be TRUE or FALSE", call. = FALSE)
            work <- if (private$loaded && !discard) private$unsaved_work()
            if (!is.null(work))
                stop("[", site, "] the current object has work not saved: ", work,
                    "; save it with save(name), or pass `discard = TRUE` to drop it",
                    call. = FALSE)
        },

        # A request from the page (`ask`), answered to that page only with
        # `answer` {id, data, error, code}. The start page lists projects and
        # their snapshots and opens one (adr/0019); the Data panel lists
        # what can be pulled and pulls it, which only a page showing the
        # current object may do (adr/0017). An op that runs a job (an item,
        # a pull) returns NULL and answers through `reply` when it ends.
        answer = function(ws, id, dat) {
            reply <- function(res) {
                if (!is.null(res$error)) res$error <- .console_text(res$error)
                try(ws$send(.encode_ws_message("answer", c(list(id = id), res))), silent = TRUE)
            }
            res <- if (isTRUE(dat$op %in% .lens_object_ops) && !private$conn_current(ws)) {
                list(error = "the page shows an earlier object; reload it", code = "stale")
            } else {
                tryCatch(private$ask(dat, reply), error = function(e)
                    list(error = conditionMessage(e)))
            }
            if (!is.null(res)) reply(res)
        },

        ask = function(dat, reply) {
            str1 <- function(v) if (is.character(v) && length(v) == 1L && !is.na(v)) v
            switch(str1(dat$op) %||% "",
                projects = {
                    recent <- .recent_projects()
                    list(data = list(
                        current = if (!is.null(private$project)) private$project@path,
                        recent  = lapply(seq_len(nrow(recent)), function(i) list(
                            path = recent$path[[i]], opened = recent$opened[[i]],
                            exists = file.exists(file.path(recent$path[[i]], "giottodir.json")))),
                        browse  = .can_browse()))
                },
                browse = list(data = list(path = .browse_folder())),
                snapshots = {
                    src <- .project_source(str1(dat$path), "LensViewer")
                    current <- !is.null(private$project) &&
                        identical(normalizePath(private$project@path), src@path)
                    list(data = list(path = src@path,
                        current = if (current) private$snapshot,
                        snapshots = .project_snapshots(src),
                        saves = .project_saves(src, if (current) private$saved_tag)))
                },
                # A save of a project, or the work a viewer that ended left
                # there (adr/0026); refused as `open` is
                open_save = {
                    work <- if (private$loaded && !isTRUE(dat$discard)) private$unsaved_work()
                    if (!is.null(work))
                        return(list(error = paste0("the current object has work not saved: ", work),
                            code = "work"))
                    src <- .project_source(str1(dat$path), "LensViewer")
                    private$open_save_in(src, str1(dat$name), TRUE, "LensViewer")
                    list(data = list(snapshot = private$snapshot, save = private$saved_tag))
                },
                # The tools bar's save button
                save = {
                    name <- str1(dat$name) %||% ""
                    if (!isTRUE(dat$overwrite) && !is.null(private$project) &&
                            name %in% .lens_saves(private$project)$name)
                        return(list(error = paste0("a save named '", name, "' exists"),
                            code = "exists"))
                    desc <- str1(dat$description)
                    tag <- self$save(name, description = if (nzchar(desc %||% "")) desc,
                        overwrite = isTRUE(dat$overwrite))
                    list(data = list(save = tag))
                },
                open = {
                    work <- if (private$loaded && !isTRUE(dat$discard)) private$unsaved_work()
                    if (!is.null(work))
                        return(list(error = paste0("the current object has work not saved: ", work),
                            code = "work"))
                    src  <- .project_source(str1(dat$path), "LensViewer")
                    name <- str1(dat$name)
                    private$open_snapshot(src, name, spat_unit = str1(dat$spat_unit) %||% NA,
                        feat_type = str1(dat$feat_type) %||% NA, site = "LensViewer")
                    private$add_log("open", list(path = src@path, name = name))
                    message("[LensViewer] the viewer opened snapshot '", name, "' of ", src@path)
                    list(data = list(snapshot = private$snapshot))
                },
                catalog = list(data = .catalog_payload(private$need_catalog("LensViewer"))),
                # One item's file, for a field that shows it (data/items.ts)
                item = {
                    private$need_item(str1(dat$key) %||% "", "LensViewer", reply)
                    NULL
                },
                # keys: [{source, items: [...], types: [...]}], a type per item
                # ("auto" for as the values are)
                pull = {
                    cat <- private$need_catalog("LensViewer")
                    keys <- dat$keys
                    if (!is.list(keys) || !length(keys))
                        return(list(error = "nothing to pull"))
                    rows <- do.call(rbind, lapply(keys, function(k) {
                        items <- as.character(unlist(k$items))
                        types <- as.character(unlist(k$types) %||% rep("auto", length(items)))
                        if (length(types) != length(items))
                            stop("[LensViewer] a type per item", call. = FALSE)
                        data.frame(source = rep(as.integer(k$source %||% NA), length(items)),
                            item = items, type = types)
                    }))
                    # `ref` names the job in its `job` messages, for the page to cancel it
                    private$pull_items(.pull_items(cat, rows, site = "LensViewer"), function(r)
                        reply(.job_answer(r, function(added) list(columns = as.list(added)))),
                        ref = str1(dat$ref))
                    NULL
                },
                # The Regions panel: save, remove, select, compare. A compare
                # is answered when its job ends, with the result's id.
                region = {
                    name <- str1(dat$name) %||% ""
                    switch(str1(dat$action) %||% "",
                        save   = list(data = list(cells = length(self$save_region(name)))),
                        remove = { self$remove_region(name); list(data = list()) },
                        select = { self$select_region(name); list(data = list()) },
                        compare = {
                            b <- str1(dat$b)
                            private$compare(str1(dat$a) %||% "", if (nzchar(b %||% "")) b,
                                str1(dat$values), "LensViewer", ref = str1(dat$ref),
                                function(r) reply(.job_answer(r, function(id) list(id = id))))
                            NULL
                        },
                        list(error = "unknown region action"))
                },
                # A job the page started (its `job` messages carry the id)
                cancel_job = list(data = list(cancelled = is.numeric(dat$id) && length(dat$id) == 1L &&
                    private$cancel(dat$id))),
                # The cell table's rows in view: IDs of cell indices (0-based).
                # The page keys nothing by ID (adr/0002).
                cell_ids = {
                    i <- unlist(dat$cells)
                    n <- length(private$cell_ids)
                    if (!is.numeric(i) || !length(i) || length(i) > 5000L || anyNA(i) ||
                            any(i != round(i) | i < 0 | i >= n))
                        return(list(error = "`cells` must be up to 5000 cell indices"))
                    list(data = list(ids = as.list(private$cell_ids[i + 1L])))
                },
                list(error = "unknown request")
            )
        },

        save_snapshot = function(src, x, keep) {
            # qs2 when installed: on the Atera section it writes in 0.4 to 1 s
            # where gzip RDS takes 5.4 s, and reads faster
            suppressMessages(GiottoDisk::snapshotSave(src, x, name = .lens_snapshot_name(src),
                keep = keep, creator = "GiottoLens", session = private$session_id,
                method = if (requireNamespace("qs2", quietly = TRUE)) "qs2" else "rds",
                verbose = FALSE))
        },

        # ── The working bundle and saves (R/bundle.R, adr/0026) ──
        work         = NULL,     # the working bundle's directory, normalized
        work_created = NULL,
        object_uid   = NULL,     # objUID() of the snapshot shown
        cells_fp     = NULL,     # .cells_fingerprint() of the cells shown
        saved_sig    = NULL,     # work_sig() as last saved or opened
        written_sig  = NULL,     # what the working bundle last got
        written_regions = NULL,  # region_md5 as regions.parquet last got it
        saved_tag    = NULL,     # the save last made or opened
        added_args   = list(),   # add_image() arguments by image name, to add them again
        region_md5   = list(),   # region name -> md5 of its cell IDs
        registration_msg = NULL, # the last registration_update, as the page sent it

        # The working bundle: lens/session-<session id>/ in the project of the
        # object shown, else a folder in the temp dir. Served as work/.
        set_work = function() {
            dir <- if (!is.null(private$project) && private$loaded)
                file.path(.lens_dir(private$project), .work_name(private$session_id))
            else file.path(private$session, "work")
            for (d in c("metadata", "panels"))
                dir.create(file.path(dir, d), recursive = TRUE, showWarnings = FALSE)
            private$work <- normalizePath(dir)
            private$routes$work <- private$work
            private$work_created <- as.numeric(Sys.time())
            private$written_sig <- private$written_regions <- NULL
            private$object_uid <- if (!is.null(private$project) && !is.null(private$snapshot)) {
                info <- GiottoDisk::snapshotInfo(private$project)
                uid <- info$object[info$tag == private$snapshot]
                if (length(uid) && !is.na(uid[[1L]])) uid[[1L]]
            }
            private$cells_fp <- if (!is.null(private$cell_ids)) .cells_fingerprint(private$cell_ids)
            private$saved_sig <- private$work_sig()
        },

        # The work, as state.json holds it. Regions are in regions.parquet,
        # comparison tables in de/; here only what tells them apart.
        state_list = function() list(
            rules = private$rule_set, combine = private$combine,
            annotations = self$annotations, registration = private$registration_msg,
            regions = private$region_md5, pushed = private$pushed,
            meta = private$cached_meta, meta_values = private$meta_values,
            col_types = private$col_types, added = unname(private$added_args),
            de = lapply(names(private$de), function(id) c(list(id = id,
                file = paste0("de/", id, ".parquet")),
                private$de[[id]][setdiff(names(private$de[[id]]), "table")]))),
        work_sig = function() .bundle_json(private$state_list()),

        bundle_info = function(kind) list(format = .bundle_format, kind = kind,
            created = private$work_created, updated = as.numeric(Sys.time()),
            creator = "GiottoLens", session = private$session_id,
            host = Sys.info()[["nodename"]], pid = Sys.getpid(),
            snapshot = private$snapshot, object = private$object_uid,
            spat_unit = private$spat_unit, feat_type = private$feat_type,
            cells = private$cells_fp),

        # Write the working bundle when the work or the config changed since
        # the last write (or always, with `force`)
        write_state = function(force = FALSE) {
            if (!private$loaded || is.null(private$work) || !dir.exists(private$work))
                return(invisible(FALSE))
            st <- private$state_list()
            sig <- .bundle_json(list(st, private$config_json))
            if (!force && identical(sig, private$written_sig)) return(invisible(FALSE))
            w <- private$work
            regions <- file.path(w, "regions.parquet")
            if (length(private$region_sets)) {
                if (!identical(private$region_md5, private$written_regions)) {
                    tmp <- tempfile(".tmp", tmpdir = w)
                    arrow::write_parquet(data.frame(
                        region = rep(names(private$region_sets), lengths(private$region_sets)),
                        cell_ID = unlist(private$region_sets, use.names = FALSE)), tmp)
                    file.rename(tmp, regions)
                }
            } else unlink(regions)
            st$regions <- length(private$region_sets) > 0L
            st$region_names <- as.list(names(private$region_sets))
            if (length(private$de)) dir.create(file.path(w, "de"), showWarnings = FALSE)
            for (d in st$de) {
                f <- file.path(w, d$file)
                if (!file.exists(f)) arrow::write_parquet(private$de[[d$id]]$table, f)
            }
            .write_json_atomic(st, file.path(w, "state.json"))
            if (!is.null(private$config_json))
                .write_text_atomic(private$config_json, file.path(w, "config.json"))
            .write_json_atomic(private$bundle_info("session"), file.path(w, "bundle.json"))
            private$written_sig <- sig
            private$written_regions <- private$region_md5
            invisible(TRUE)
        },

        # Write the working bundle every second or so while the viewer runs
        # (option GiottoLens.autosave_interval, seconds)
        autosave = function() {
            later::later(function() {
                if (is.null(private$server)) return()
                tryCatch(private$write_state(), error = function(e)
                    private$add_log("error", list(where = "autosave", message = conditionMessage(e))))
                private$autosave()
            }, getOption("GiottoLens.autosave_interval", 1))
        },

        # The work not saved, as text, or NULL: lens_work() when it changed
        # since the last save or opening, and an analysis, which is not saved
        unsaved_work = function() {
            work <- private$lens_work()
            if (is.null(work)) return(NULL)
            if (private$work_changed()) return(work)
            if (!is.null(private$lens_analysis) && private$lens_analysis$has_work())
                "an analysis (analyses are not saved yet)"
        },
        # Whether there is work a save would keep that changed since the last
        # save or opening
        work_changed = function() !is.null(private$lens_work()) &&
            !identical(private$work_sig(), private$saved_sig),

        # open_save() in project `src`, also from the start page
        open_save_in = function(src, name, discard, site) {
            hit <- .find_save(src, name, site)
            if (hit$kind == "session") {
                if (identical(normalizePath(hit$dir), private$work))
                    stop("[", site, "] '", name, "' is this viewer's own work", call. = FALSE)
                if (isTRUE(hit$live))
                    stop("[", site, "] '", name, "' is the work of a viewer still running",
                        call. = FALSE)
            }
            private$check_work(site, discard)
            private$open_bundle(src, hit, site)
        },

        # Show bundle `hit` (a row of .lens_saves()) of project `src`: its
        # snapshot, then its work
        open_bundle = function(src, hit, site) {
            dir <- hit$dir
            b <- .read_bundle_json(file.path(dir, "bundle.json"))
            st <- .read_bundle_json(file.path(dir, "state.json"))
            if (is.null(b) || is.null(st))
                stop("[", site, "] '", hit$name, "' cannot be read", call. = FALSE)
            info <- GiottoDisk::snapshotInfo(src)
            snap <- info$name[info$tag == (b$snapshot %||% "")]
            if (!length(snap))
                stop("[", site, "] the snapshot '", b$snapshot %||% "?", "' that '", hit$name,
                    "' was made on was deleted", call. = FALSE)
            cfg <- .bundle_file(dir, "config.json")
            config <- if (!is.null(cfg)) paste(readLines(cfg, warn = FALSE, encoding = "UTF-8"),
                collapse = "\n")
            str1 <- function(v) if (is.character(v) && length(v) == 1L) v else NA
            private$open_snapshot(src, snap[[1L]], spat_unit = str1(b$spat_unit),
                feat_type = str1(b$feat_type), site = site)
            private$restore_state(dir, st, b, config, site)
            if (hit$kind == "save") {
                private$saved_sig <- private$work_sig()
                private$saved_tag <- basename(dir)
            } else unlink(dir, recursive = TRUE)
            private$write_state(force = TRUE)
            private$add_log("open_save", hit$name)
            message("[LensViewer] the viewer opened '", hit$name, "' of ", src@path)
        },

        # The work of bundle `dir` (`st` its state.json, `b` its bundle.json)
        # onto the object just shown, its files copied into the working bundle
        restore_state = function(dir, st, b, config, site) {
            w <- private$work
            for (f in .bundle_files(st)) {
                src <- .bundle_file(dir, f)
                if (is.null(src)) next
                dest <- file.path(w, f)
                dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
                file.copy(src, dest, overwrite = TRUE)
            }
            fp <- private$cells_fp
            same <- identical(as.integer(b$cells$n), as.integer(fp$n)) &&
                identical(b$cells$md5, fp$md5)
            dropped <- character()
            private$config_json <- config
            # Metadata and panel rows are in the order of the cells saved with
            if (same) {
                if (is.list(st$meta) && is.list(st$meta$columns)) {
                    # A column whose file was not copied is left out
                    read <- vapply(st$meta$columns, function(cl) is.character(cl$url) &&
                        file.exists(file.path(w, sub("^work/", "", cl$url))), NA)
                    if (!all(read)) dropped <- c(dropped, "metadata files that could not be read")
                    st$meta$columns <- st$meta$columns[read]
                    private$cached_meta <- if (length(read) && any(read)) st$meta
                    private$meta_values <- lapply(st$meta_values %||% list(),
                        function(v) as.numeric(unlist(v)))
                }
            } else if (length(st$meta$columns)) dropped <- c(dropped, "metadata")
            private$col_types <- lapply(st$col_types %||% list(), function(v) as.character(unlist(v)))
            ok_rule <- function(r) !inherits(tryCatch(.validate_rule(r, site), error = function(e) e), "error")
            rules <- Filter(ok_rule, st$rules %||% list())
            if (!same && any(vapply(rules, .rule_has_ids, NA))) {
                rules <- Filter(Negate(.rule_has_ids), rules)
                dropped <- c(dropped, "rules naming cells by position")
            }
            # Rules on metadata left out cannot be evaluated
            ctx <- private$eval_ctx()
            evaluates <- function(r) !inherits(tryCatch(.eval_rule(r, ctx), error = function(e) e), "error")
            if (!all(vapply(rules, evaluates, NA))) {
                rules <- Filter(evaluates, rules)
                dropped <- c(dropped, "rules on columns left out")
            }
            private$rule_set <- rules
            if (isTRUE(st$combine %in% c("and", "or"))) private$combine <- st$combine
            if (length(rules)) {
                hit <- .combine_rules(rules, private$eval_ctx(), private$combine)
                self$selection <- private$cell_ids[hit]
                self$selection_rules <- unname(rules)
            }
            self$annotations <- lapply(st$annotations %||% list(), function(a) list(
                id = as.character(a$id %||% ""), name = as.character(a$name %||% ""),
                type = as.character(a$type %||% ""), geojson = as.character(a$geojson %||% "")))
            if (is.list(st$registration)) {
                private$registration_msg <- st$registration
                self$registration <- .parse_registration(st$registration)
            }
            if (isTRUE(st$regions) && file.exists(file.path(w, "regions.parquet"))) {
                r <- arrow::read_parquet(file.path(w, "regions.parquet"))
                r <- r[r$cell_ID %in% private$cell_ids, , drop = FALSE]
                order <- intersect(as.character(unlist(st$region_names)), unique(r$region))
                for (n in order) {
                    private$region_sets[[n]] <- r$cell_ID[r$region == n]
                    private$region_md5[[n]] <- .strings_md5(private$region_sets[[n]])
                }
            }
            # Rows linked to cells carry their index (`_idx`)
            linked <- function(p) if (!is.null(p$data_url))
                "_idx" %in% arrow::open_dataset(file.path(w, sub("^work/", "", p$data_url)))$schema$names
                else "_idx" %in% names(p$spec$data$values[[1L]] %||% list())
            pushed <- Filter(function(p) is.character(p$id) && length(p$id) == 1L &&
                (is.null(p$data_url) || (startsWith(p$data_url, "work/panels/") &&
                    file.exists(file.path(w, sub("^work/", "", p$data_url))))) &&
                (same || !linked(p)), st$pushed %||% list())
            if (length(pushed) < length(st$pushed)) dropped <- c(dropped, "panels linked to cells")
            private$pushed <- stats::setNames(pushed, vapply(pushed, function(p) p$id, ""))
            seqs <- suppressWarnings(as.integer(sub("^panel-", "", names(private$pushed))))
            private$panel_seq <- max(c(0L, seqs), na.rm = TRUE)
            for (d in st$de %||% list()) {
                f <- file.path(w, d$file %||% "")
                if (!is.character(d$id) || !file.exists(f)) next
                private$de[[d$id]] <- c(d[setdiff(names(d), c("id", "file"))],
                    list(table = as.data.frame(arrow::read_parquet(f))))
            }
            seqs <- suppressWarnings(as.integer(sub("^de-", "", names(private$de))))
            private$de_seq <- max(c(0L, seqs), na.rm = TRUE)
            for (a in st$added %||% list()) {
                r <- tryCatch(self$add_image(as.character(a$file), name = as.character(a$name),
                    type = as.character(a$type)), error = function(e) e)
                if (inherits(r, "error")) warning("[", site, "] image '", a$name,
                    "' was not added again: ", conditionMessage(r), call. = FALSE)
            }
            if (length(dropped))
                warning("[", site, "] left out: ", paste(unique(dropped), collapse = ", "),
                    if (!same) " (the cells differ from those saved)", call. = FALSE)
            invisible()
        },

        # Jobs (R/jobs.R, adr/0025)
        job_profile  = NULL,     # the jobs' mirai compute profile, from the first job
        running_jobs = list(),   # by id: an environment per job
        job_seq      = 0L,

        # Run `fun(g, ...)` (`args`) over the object shown in the jobs'
        # daemon. On the main thread when it ends: `apply(value)` if it
        # succeeded and the object shown is still the one it started from,
        # then `on_end(list(state, result, message))` whatever happened
        # (`state`: done, error or cancelled). Every tab hears of it as a
        # `job` message carrying `ref`, the page's name for it, and with
        # `progress = TRUE` how far it is (.lens_progress()). Returns its id.
        start_job = function(label, fun, args = list(), apply = identity, ref = NULL,
                             on_end = NULL, progress = FALSE) {
            private$need_object("LensViewer")
            if (is.null(private$project))
                stop("[LensViewer] jobs need an object shown from a snapshot", call. = FALSE)
            if (is.null(private$job_profile))
                private$job_profile <- .job_daemon(paste0("giottolens-", self$port, "-", .rand_id(6L)))
            id <- private$job_seq <- private$job_seq + 1L
            job <- new.env(parent = emptyenv())
            job$id <- id
            job$label <- label
            job$ref <- ref
            job$load <- private$load_seq
            job$started <- Sys.time()
            job$cancelled <- FALSE
            job$file <- if (isTRUE(progress)) {
                dir.create(file.path(private$session, "jobs"), showWarnings = FALSE)
                file.path(private$session, "jobs", paste0(id, ".progress"))
            }
            # .args, not `...`: kept out of the daemon's global environment,
            # which keeps the object between jobs
            job$m <- mirai::mirai(.jw_run(fun, args, path, name, progress), .args = list(
                fun = .job_fun(fun), args = args, path = private$project@path,
                name = private$snapshot_name(), progress = job$file), .compute = private$job_profile)
            private$running_jobs[[as.character(id)]] <- job
            private$job_message(job, "running")
            if (!is.null(job$file)) private$poll_progress(job)
            end <- function(state, result = NULL, msg = NULL) {
                private$running_jobs[[as.character(id)]] <- NULL
                if (!is.null(job$file)) unlink(paste0(job$file, c("", ".tmp")))
                private$job_message(job, state, msg)
                if (!is.null(on_end)) on_end(list(state = state, result = result, message = msg))
            }
            promises::then(job$m,
                onFulfilled = function(value) {
                    if (!identical(private$load_seq, job$load))
                        return(end("cancelled", msg = "the object shown changed"))
                    res <- tryCatch(list(ok = apply(value)), error = function(e) e)
                    if (inherits(res, "error")) end("error", msg = conditionMessage(res))
                    else end("done", result = res$ok)
                },
                # A cancel rejects too ("Operation canceled"): told apart by
                # the job's own flag
                onRejected = function(e) {
                    if (job$cancelled) end("cancelled", msg = job$why)
                    else end("error", msg = .job_error_text(e))
                })
            id
        },
        # start_job() and wait for it, pumping the event loop: its result, or
        # an error naming `site`. Cancelled after `timeout` seconds.
        run_job = function(site, label, fun, args = list(), apply = identity, timeout = Inf) {
            out <- NULL
            id <- private$start_job(label, fun, args, apply, on_end = function(r) out <<- r)
            t0 <- Sys.time()
            while (is.null(out)) {
                if (as.numeric(Sys.time() - t0, units = "secs") > timeout)
                    private$cancel(id, paste("timed out after", timeout, "s"))
                later::run_now(0.05)
            }
            if (out$state != "done")
                stop("[", site, "] ", label, " ", out$state, ": ", out$message, call. = FALSE)
            out$result
        },
        # The job's progress file, while it runs
        poll_progress = function(job) {
            later::later(function() {
                if (is.null(private$running_jobs[[as.character(job$id)]])) return()
                p <- .read_progress(job$file)
                if (!is.null(p) && !identical(p, job$progress)) {
                    job$progress <- p
                    private$job_message(job, "running")
                }
                private$poll_progress(job)
            }, 0.25)
        },
        cancel = function(id, why = "cancelled") {
            job <- private$running_jobs[[as.character(id)]]
            if (is.null(job) || job$cancelled) return(FALSE)
            job$cancelled <- TRUE
            job$why <- why
            isTRUE(mirai::stop_mirai(job$m))
        },
        job_message = function(job, state, msg = NULL) {
            if (self$connected()) private$broadcast(private$job_json(job, state, msg))
        },
        # `started` in seconds since the epoch, so a page that connects later
        # shows how long a job has run
        job_json = function(job, state, msg = NULL) {
            .encode_ws_message("job", Filter(Negate(is.null), list(id = job$id, label = job$label,
                ref = job$ref, state = state, message = msg, progress = job$progress,
                started = as.numeric(job$started))))
        },
        stop_jobs = function() {
            for (id in names(private$running_jobs)) private$cancel(id, "the viewer was closed")
            .job_stop_daemon(private$job_profile)
            private$job_profile <- NULL
            private$running_jobs <- list()
        },

        snapshot_name = function() {
            info <- GiottoDisk::snapshotInfo(private$project)
            name <- info$name[info$tag == private$snapshot]
            if (!length(name))
                stop("[LensViewer] the snapshot shown (", private$snapshot,
                    ") was deleted", call. = FALSE)
            name
        },

        # Drop what belonged to the object shown: nothing is kept for when it
        # is shown again (adr/0017). Keeping Lens work is a save's job;
        # set_object() refuses to drop work unless told to.
        clear_object = function() {
            private$close_analysis()
            private$added_images <- list()
            private$added_args   <- list()
            unlink(file.path(private$session, "images_added.json"))
            # Its working bundle: saved, or dropped by choice (check_work())
            if (!is.null(private$work)) unlink(private$work, recursive = TRUE)
            private$work <- NULL
            .prune_meta_files(private$items_dir(), character())
            private$item_files   <- list()
            # Their jobs were cancelled by load(); answered here, as the
            # cancels end after the next object's reads may have started
            for (read in private$item_reads)
                for (w in read$waits) w(list(error = "the object shown changed"))
            private$item_reads   <- list()
            private$region_sets  <- list()
            private$region_md5   <- list()
            private$de           <- list()
            private$owned        <- list()
            private$config_json  <- NULL
            private$rule_set     <- list()
            private$combine      <- "and"
            private$pushed       <- list()
            private$cached_meta  <- NULL
            private$meta_values  <- list()
            private$col_types    <- list()
            private$catalog_data <- NULL
            private$cells_xy     <- NULL
            self$annotations     <- list()
            self$registration    <- NULL
            private$registration_msg <- NULL
            private$saved_tag    <- NULL
            self$selection       <- NULL
            self$selection_rules <- NULL
        },

        # The work done in the viewer on the object shown, as text ("2 rules,
        # 1 annotation"), or NULL for none: what set_object() will not drop
        # without `discard = TRUE`. Settings are not counted.
        lens_work = function() {
            n <- c(rule = length(private$rule_set), annotation = length(self$annotations),
                region = length(private$region_sets), `pushed panel` = length(private$pushed),
                `added image` = length(private$added_images))
            parts <- sprintf("%d %s%s", n, names(n), ifelse(n == 1L, "", "s"))[n > 0L]
            if (!is.null(self$registration)) parts <- c(parts, "image registration")
            if (!is.null(private$lens_analysis) && private$lens_analysis$has_work())
                parts <- c(parts, "an analysis")
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
                stop("[", site, "] no object loaded; call viewer$set_object(g)",
                    if (!is.null(private$project)) " or viewer$checkout(name)", " first",
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
                            ws$send(.encode_ws_message("preferences", .lens_pref_msg()))
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
                            # Jobs already running: a reload or a new tab lists them too
                            for (j in priv$running_jobs) ws$send(priv$job_json(j, "running"))
                            ws$send(.encode_ws_message("regions", priv$regions_msg()))
                            if (!is.null(priv$lens_analysis)) priv$lens_analysis$on_ready(ws)
                        },
                        # A click on a point of a pushed chart's `pick` param:
                        # on a volcano plot, colour the cells by that gene; on
                        # an analysis panel, the analysis acts on it
                        panel_pick = if (is.character(dat$id) && length(dat$id) == 1L) {
                            if (!is.null(priv$de[[dat$id]]))
                                priv$pick_gene(ws, dat$id, unlist(dat$value$gene)[1L])
                            else if (!is.null(priv$lens_analysis))
                                priv$analysis_message(ws, "panel_pick", dat)
                        },
                        analysis_param = , analysis_labels = , analysis_cancel = , analysis_settings = ,
                        analysis_region = , analysis_run = , analysis_add = , analysis_remove = ,
                        analysis_history = , analysis_feature = , analysis_open =
                            priv$analysis_message(ws, parsed$type, dat),
                        ask = priv$answer(ws, parsed$id, dat),
                        # The Preferences dialog (the tools bar's gear)
                        preferences_set = tryCatch(.lens_pref_from_viewer(dat),
                            error = function(e) {
                                priv$add_log("error", list(where = "preferences",
                                    message = conditionMessage(e)))
                                warning("[LensViewer] ", .console_text(conditionMessage(e)),
                                    call. = FALSE)
                                .lens_pref_broadcast()
                            }),
                        # The images panel's "add image" button
                        choose_image = {
                            type <- if (is.character(dat$type) && length(dat$type) == 1L) dat$type else "if"
                            later::later(function() priv$choose_image(ws, type))
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
                        # The stop button: after this callback, so the server
                        # is not stopped from inside its own handler
                        close = later::later(function() {
                            message("[LensViewer] stopped from the viewer")
                            pub$close()
                        }),
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
                            if (parsed$type == "registration_update")
                                priv$registration_msg <- dat
                            if (parsed$type == "cell_selection") {
                                priv$sel_seq <- priv$sel_seq + 1L
                                rules <- dat$rules %||% list()
                                names(rules) <- vapply(rules, function(r) r$source %||% "", "")
                                priv$rule_set   <- rules
                                priv$combine <- dat$combine %||% "and"
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
.lens_builtin_panels <- c("spatial", "tools", "scatter", "histogram", "density", "table", "cells",
    "transcripts", "data", "regions", "analysis", "images", "register", "annotations", "layers")

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
