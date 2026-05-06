# ── serve_atlas() ─────────────────────────────────────────────────────────────

#' Set up the GiottoAtlas data directory
#'
#' Derives all paths from the GiottoDisk store objects, copies viewer files,
#' and generates the manifest.  The HTTP server is started by [launch_atlas()].
#'
#' @param gpoints    giottoPoints object (optional)
#' @param gpolygons  giottoPolygon object (optional)
#' @param port       Port for the combined HTTP + WebSocket server (default: 3000)
#' @param url_prefix Override the URL prefix (default: `http://localhost:{port}`)
#' @return An [AtlasServer] configuration object
#' @export
serve_atlas <- function(
    gpoints    = NULL,
    gpolygons  = NULL,
    port       = 3000L,
    url_prefix = paste0("http://localhost:", port)
) {
    serve_root <- .derive_serve_root(gpoints, gpolygons)
    atlas_dir  <- file.path(serve_root, "atlas")
    dir.create(atlas_dir, recursive = TRUE, showWarnings = FALSE)

    viewer_src   <- .viewer_src_dir()
    viewer_files <- list.files(viewer_src, full.names = TRUE)
    copied <- file.copy(viewer_files, atlas_dir, overwrite = TRUE)
    message("Copied ", sum(copied), "/", length(copied),
            " viewer files to: ", atlas_dir)
    if (!all(copied))
        warning("Some viewer files failed to copy: ",
                paste(basename(viewer_files[!copied]), collapse = ", "))

    export_manifest(
        gpoints    = gpoints,
        gpolygons  = gpolygons,
        output     = file.path(atlas_dir, "manifest.json"),
        serve_root = serve_root,
        url_prefix = url_prefix
    )

    AtlasServer$new(serve_root = serve_root, port = port, url_prefix = url_prefix)
}


# ── launch_atlas() ────────────────────────────────────────────────────────────

#' Open the GiottoAtlas viewer
#'
#' Starts a combined HTTP + WebSocket server via httpuv — no Node.js required.
#' Static files and parquet data are served using httpuv's C++ static path
#' handler (concurrent, Range-aware, never blocks R's event loop).  The
#' WebSocket runs on the same port so the RStudio viewer pane can connect.
#'
#' @param server An [AtlasServer] object returned by [serve_atlas()]
#' @param open   Open browser / viewer pane automatically
#' @return An [AtlasViewer] object; call `$close()` to stop the server
#' @export
launch_atlas <- function(server, open = TRUE) {
    if (!inherits(server, "AtlasServer"))
        stop("Pass the AtlasServer returned by serve_atlas()")

    viewer <- AtlasViewer$new(serve_root  = server$serve_root,
                               port        = server$port,
                               url_prefix  = server$url_prefix)
    url <- paste0(server$url_prefix, "/atlas/")
    if (open) utils::browseURL(url)
    message("Viewer: ", url)
    invisible(viewer)
}


# ── AtlasServer ───────────────────────────────────────────────────────────────

#' Configuration object returned by [serve_atlas()]
#' @export
AtlasServer <- R6::R6Class("AtlasServer",
    public = list(
        #' @field url_prefix Base URL
        url_prefix = NULL,
        #' @field port       Server port
        port       = NULL,
        #' @field serve_root Root directory being served
        serve_root = NULL,

        initialize = function(serve_root, port, url_prefix) {
            self$serve_root <- serve_root
            self$port       <- port
            self$url_prefix <- url_prefix
        },

        #' @description Shorthand for launch_atlas(server)
        open = function(open = TRUE) launch_atlas(self, open = open),

        print = function(...) {
            cat("AtlasServer\n")
            cat("  url:  ", self$url_prefix, "\n")
            cat("  root: ", self$serve_root, "\n")
            invisible(self)
        }
    )
)


# ── AtlasViewer ───────────────────────────────────────────────────────────────

#' Combined HTTP + WebSocket server returned by [launch_atlas()]
#'
#' File serving uses httpuv's C++ `staticPath` handler — concurrent and
#' Range-aware without touching R's event loop.  WebSocket messages (selection,
#' annotations) are dispatched to the main R thread and update public fields
#' directly.
#'
#' @export
AtlasViewer <- R6::R6Class("AtlasViewer",

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
            private$start_server()
        },

        #' @description Send a typed message to the viewer
        send = function(type, data = NULL) {
            if (is.null(private$ws)) {
                warning("AtlasViewer: no viewer connected yet")
                return(invisible(self))
            }
            private$ws$send(jsonlite::toJSON(
                list(type = type, data = data),
                auto_unbox = TRUE, null = "null"
            ))
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
                message("AtlasViewer: server stopped")
            }
            invisible(self)
        },

        print = function(...) {
            cat("AtlasViewer\n")
            cat("  url:         ", self$url_prefix, "\n")
            cat("  connected:   ", !is.null(private$ws), "\n")
            cat("  selection:   ", length(self$selection), "cell(s)\n")
            cat("  annotations: ", length(self$annotations), "polygon(s)\n")
            invisible(self)
        }
    ),

    private = list(
        root   = NULL,
        ws     = NULL,
        server = NULL,
        cbs    = list(),

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
                            ws$onMessage(function(binary, msg) {
                                tryCatch({
                                    parsed <- jsonlite::fromJSON(msg,
                                                 simplifyVector = FALSE)
                                    type <- parsed$type
                                    dat  <- parsed$data

                                    if (identical(type, "cell_selection"))
                                        pub$selection <- if (length(dat$ids))
                                            unlist(dat$ids) else character(0)

                                    if (identical(type, "annotation") &&
                                            !is.null(dat$geojson))
                                        pub$annotations <- c(pub$annotations,
                                                             list(dat$geojson))

                                    cb <- priv$cbs[[type]]
                                    if (!is.null(cb))
                                        later::later(function() cb(dat), delay = 0)

                                }, error = function(e)
                                    warning("AtlasViewer message error: ", e$message))
                            })
                            message("AtlasViewer: viewer connected")
                        }
                    )
                )
                message("AtlasViewer: server started at ", self$url_prefix)
            }, error = function(e)
                stop("AtlasViewer: failed to start server on port ", self$port,
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
    installed <- system.file("viewer", package = "GiottoAtlas")
    if (nzchar(installed)) return(installed)
    pkg_path <- tryCatch(find.package("GiottoAtlas"), error = function(e) "")
    if (nzchar(pkg_path)) {
        path <- file.path(pkg_path, "viewer")
        if (dir.exists(path)) return(normalizePath(path))
    }
    stop("Cannot locate viewer files. ",
         "Ensure GiottoAtlas is loaded via devtools::load_all() or installed.")
}

.random_port <- function() sample(49152L:65535L, 1L)