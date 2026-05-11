# ── launch_lens() ────────────────────────────────────────────────────────────

#' Launch the GiottoLens viewer
#'
#' Sets up data files, exports the manifest, starts a combined HTTP + WebSocket
#' server via httpuv, and opens the viewer.  Static files and parquet data are
#' served via httpuv's C++ static path handler (concurrent, Range-aware, never
#' blocks R's event loop).  The WebSocket runs on the same port so the RStudio
#' viewer pane can connect without cross-port restrictions.
#'
#' @param x          A giotto object **or** a giottoPoints store.
#' @param gpolygons  giottoPolygon store.  Ignored when `x` is a giotto object.
#' @param feat_type  Feature type key when `x` is a giotto object (default `"rna"`).
#' @param spat_unit  Spatial unit key when `x` is a giotto object (default `"cell"`).
#' @param port       Port for the HTTP + WebSocket server (default: 3000).
#' @param url_prefix Override the base URL (default: `http://localhost:{port}`).
#' @param open       Open browser / viewer pane automatically (default: `TRUE`).
#' @return An [LensViewer] object; call `$close()` to stop the server.
#' @export
launch_lens <- function(
    x          = NULL,
    gpolygons  = NULL,
    feat_type  = "rna",
    spat_unit  = "cell",
    port       = 3000L,
    url_prefix = paste0("http://localhost:", port),
    open       = TRUE
) {
    if (inherits(x, "giotto")) {
        gpoints   <- x@feat_info[[feat_type]]
        gpolygons <- x@spatial_info[[spat_unit]]
    } else {
        gpoints <- x
    }
    serve_root <- .derive_serve_root(gpoints, gpolygons)
    lens_dir   <- file.path(serve_root, "lens")
    dir.create(lens_dir, recursive = TRUE, showWarnings = FALSE)

    viewer_src   <- .viewer_src_dir()
    viewer_files <- list.files(viewer_src, full.names = TRUE)
    copied <- file.copy(viewer_files, lens_dir, overwrite = TRUE)
    if (!all(copied))
        warning("Some viewer files failed to copy: ",
                paste(basename(viewer_files[!copied]), collapse = ", "))

    export_manifest(
        gpoints    = gpoints,
        gpolygons  = gpolygons,
        output     = file.path(lens_dir, "manifest.json"),
        serve_root = serve_root,
        url_prefix = url_prefix
    )

    viewer <- LensViewer$new(serve_root = serve_root,
                               port       = port,
                               url_prefix = url_prefix)
    url <- paste0(url_prefix, "/lens/")
    if (open) utils::browseURL(url)
    message("Viewer: ", url)
    invisible(viewer)
}

#' @rdname launch_lens
#' @description `serve_lens()` is a deprecated alias for [launch_lens()] kept
#'   for backward compatibility.
#' @export
serve_lens <- function(...) {
    .Deprecated("launch_lens")
    launch_lens(...)
}



# ── LensViewer ───────────────────────────────────────────────────────────────

#' Combined HTTP + WebSocket server returned by [launch_lens()]
#'
#' File serving uses httpuv's C++ `staticPath` handler — concurrent and
#' Range-aware without touching R's event loop.  WebSocket messages (selection,
#' annotations) are dispatched to the main R thread and update public fields
#' directly.
#'
#' @export
LensViewer <- R6::R6Class("LensViewer",

    public = list(
        #' @field port        Server port
        port        = NULL,
        #' @field url_prefix  Base URL
        url_prefix  = NULL,
        #' @field selection   Character vector of selected cell IDs; updated on each lasso
        selection   = NULL,
        #' @field annotations List of GeoJSON strings from drawn polygons
        annotations = list(),

        initialize = function(serve_root, port, url_prefix) {
            self$port      <- port
            self$url_prefix <- url_prefix
            private$root   <- serve_root
            reg.finalizer(self, function(v) v$close(), onexit = TRUE)
            private$start_server()
        },

        #' @description Send a typed message to the viewer
        send = function(type, data = NULL) {
            if (is.null(private$ws)) {
                warning("LensViewer: no viewer connected yet")
                return(invisible(self))
            }
            private$ws$send(jsonlite::toJSON(
                list(type = type, data = data),
                auto_unbox = TRUE, null = "null"
            ))
            invisible(self)
        },

        #' @description Push cell metadata to the viewer for polygon coloring
        #' @param x         A giotto object, or a data.frame / output of [prep_meta()]
        #' @param cols      Columns to include (NULL = all; ignored when x is a data.frame)
        #' @param dimreds   Dimension reduction names to include, e.g. `c("umap","tsne")`
        #' @param dims      Axes to pull from each reduction (default `1:2`)
        #' @param spat_unit Spatial unit key (default `"cell"`)
        #' @param feat_type Feature type key for dim reds (default `"rna"`)
        push_metadata = function(x, cols = NULL, dimreds = NULL, dims = 1:2,
                                 spat_unit = "cell", feat_type = "rna") {
            if (is.null(private$ws)) {
                warning("LensViewer: no viewer connected yet")
                return(invisible(self))
            }
            if (inherits(x, "giotto")) {
                meta <- prep_meta(x, cols = cols, dimreds = dimreds, dims = dims,
                                  spat_unit = spat_unit, feat_type = feat_type)
            } else {
                meta <- as.data.frame(x)
            }
            id_col <- if ("cell_ID" %in% names(meta)) "cell_ID" else names(meta)[1]
            # Sanitise column names: dots and other special chars break SQL identifiers
            names(meta) <- gsub("[^A-Za-z0-9_]", "_", names(meta))
            id_col      <- gsub("[^A-Za-z0-9_]", "_", id_col)
            meta_dir <- file.path(private$root, "lens", "metadata")
            dir.create(meta_dir, recursive = TRUE, showWarnings = FALSE)
            path <- file.path(meta_dir, "cell_meta.parquet")
            arrow::write_parquet(meta, path)
            # Classify each column so JS doesn't have to guess
            data_cols <- setdiff(names(meta), id_col)
            col_types  <- vapply(data_cols, function(cn) {
                v <- meta[[cn]]
                if (is.factor(v) || is.character(v) || is.logical(v)) return("categorical")
                if (is.integer(v)) return("categorical")
                "continuous"
            }, character(1L))
            meta_msg <- list(url = "/lens/metadata/cell_meta.parquet",
                             types = as.list(col_types))
            private$cached_meta <- meta_msg
            self$send("load_metadata", meta_msg)
            message("LensViewer: pushed metadata — ",
                    nrow(meta), " cells, ",
                    ncol(meta) - 1L, " column(s): ",
                    paste(setdiff(names(meta), id_col), collapse = ", "))
            invisible(self)
        },

        #' @description Push a selection of cell IDs to the viewer.
        #'   If cross-filter mode is active it will be turned off so the
        #'   pushed selection is shown directly without intersection.
        #' @param ids Character vector of cell IDs to select (empty vector clears).
        set_selection = function(ids) {
            self$selection <- as.character(ids)
            self$send("set_selection", list(ids = as.list(as.character(ids))))
            invisible(self)
        },

        #' @description Register a callback for a viewer message type
        on = function(type, callback) {
            private$cbs[[type]] <- callback
            invisible(self)
        },

        #' @description Stop the HTTP + WebSocket server
        close = function() {
            if (!is.null(private$server)) {
                private$server$stop()
                private$server <- NULL
                message("LensViewer: server stopped")
            }
            invisible(self)
        },

        print = function(...) {
            cat("LensViewer\n")
            cat("  url:         ", self$url_prefix, "\n")
            cat("  connected:   ", !is.null(private$ws), "\n")
            cat("  selection:   ", length(self$selection), "cell(s)\n")
            cat("  annotations: ", length(self$annotations), "polygon(s)\n")
            invisible(self)
        }
    ),

    private = list(
        root        = NULL,
        ws          = NULL,
        server      = NULL,
        cbs         = list(),
        cached_meta = NULL,

        start_server = function() {
            priv <- private
            pub  <- self

            tryCatch({
                private$server <- httpuv::startServer(
                    host = "0.0.0.0",
                    port = self$port,
                    app  = list(
                        # C++ file handler: concurrent, Range-aware, no R event loop
                        staticPaths = list(
                            "/" = httpuv::staticPath(private$root,
                                                     indexhtml   = TRUE,
                                                     fallthrough = FALSE)
                        ),

                        onWSOpen = function(ws) {
                            priv$ws <- ws
                            # Re-push cached metadata so a browser reload or new tab
                            # gets the same data without calling push_metadata() again
                            if (!is.null(priv$cached_meta))
                                ws$send(jsonlite::toJSON(
                                    list(type = "load_metadata",
                                         data = priv$cached_meta),
                                    auto_unbox = TRUE, null = "null"
                                ))
                            ws$onMessage(function(binary, msg) {
                                tryCatch({
                                    parsed <- jsonlite::fromJSON(msg,
                                                 simplifyVector = FALSE)
                                    type <- parsed$type
                                    dat  <- parsed$data

                                    if (identical(type, "cell_selection"))
                                        pub$selection <- if (length(dat$ids))
                                            unlist(dat$ids) else character(0)

                                    if (identical(type, "annotations_update"))
                                        pub$annotations <- lapply(
                                            dat$annotations,
                                            function(a) list(
                                                id     = a[["id"]],
                                                name   = a[["name"]] %||% "",
                                                type   = a[["type"]],
                                                geojson = a[["geojson"]]
                                            )
                                        )

                                    cb <- priv$cbs[[type]]
                                    if (!is.null(cb))
                                        later::later(function() cb(dat), delay = 0)

                                }, error = function(e)
                                    warning("LensViewer message error: ", e$message))
                            })
                            message("LensViewer: viewer connected")
                        }
                    )
                )
                message("LensViewer: server started at ", self$url_prefix)
            }, error = function(e)
                stop("LensViewer: failed to start server on port ", self$port,
                     " — already in use? ", e$message))
        }
    )
)


# ── Helpers ───────────────────────────────────────────────────────────────────

.derive_serve_root <- function(gpoints, gpolygons) {
    paths <- c()
    if (!is.null(gpoints))   paths <- c(paths, gpoints@spatVector@path)
    if (!is.null(gpolygons)) paths <- c(paths, gpolygons@spatVector@path)
    if (!length(paths)) stop("Provide at least one of gpoints or gpolygons")
    roots <- unique(dirname(dirname(dirname(paths))))
    if (length(roots) > 1)
        warning("Objects appear to be in different roots; using: ", roots[[1]])
    roots[[1]]
}

.viewer_src_dir <- function() {
    installed <- system.file("viewer", package = "GiottoLens")
    if (nzchar(installed)) return(installed)
    pkg_path <- tryCatch(find.package("GiottoLens"), error = function(e) "")
    if (nzchar(pkg_path)) {
        path <- file.path(pkg_path, "viewer")
        if (dir.exists(path)) return(normalizePath(path))
    }
    stop("Cannot locate viewer files. ",
         "Ensure GiottoLens is loaded via devtools::load_all() or installed.")
}

.random_port <- function() sample(49152L:65535L, 1L)