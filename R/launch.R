# ── Step 1: serve_atlas() ─────────────────────────────────────────────────────

#' Set up and start the GiottoAtlas data server
#'
#' Derives all paths from the GiottoDisk store objects, generates the manifest,
#' copies the viewer files, and starts an HTTP server via `npx serve` as a
#' background process. Returns an [AtlasServer] handle.
#'
#' @param gpoints       giottoPoints object (optional)
#' @param gpolygons     giottoPolygon object (optional)
#' @param port          Port for the HTTP server (default: 3000)
#' @param url_prefix    Override the URL prefix (default: `http://localhost:{port}`)
#' @return An [AtlasServer] object
#' @export
serve_atlas <- function(
    gpoints    = NULL,
    gpolygons  = NULL,
    port       = 3000L,
    url_prefix = paste0("http://localhost:", port)
) {
    if (!requireNamespace("processx", quietly = TRUE))
        stop("processx required: install.packages('processx')")

    serve_root <- .derive_serve_root(gpoints, gpolygons)
    atlas_dir  <- file.path(serve_root, "atlas")
    dir.create(atlas_dir, recursive = TRUE, showWarnings = FALSE)

    # Copy viewer JS/HTML files
    viewer_src   <- .viewer_src_dir()
    viewer_files <- list.files(viewer_src, full.names = TRUE)
    copied <- file.copy(viewer_files, atlas_dir, overwrite = TRUE)
    message("Copied ", sum(copied), "/", length(copied),
            " viewer files to: ", atlas_dir)
    if (!all(copied))
        warning("Some viewer files failed to copy: ",
                paste(basename(viewer_files[!copied]), collapse = ", "))

    # Generate manifest
    export_manifest(
        gpoints    = gpoints,
        gpolygons  = gpolygons,
        output     = file.path(atlas_dir, "manifest.json"),
        serve_root = serve_root,
        url_prefix = url_prefix
    )

    AtlasServer$new(serve_root = serve_root, port = port, url_prefix = url_prefix)
}


# ── Step 2: launch_atlas() ────────────────────────────────────────────────────

#' Open the GiottoAtlas viewer
#'
#' Opens the viewer in a browser and starts the R <-> viewer WebSocket
#' communication channel. Call after [serve_atlas()].
#'
#' @param server  An [AtlasServer] object returned by [serve_atlas()]
#' @param open    Open browser automatically
#' @return An [AtlasViewer] object
#' @export
launch_atlas <- function(server, open = TRUE) {
    if (!inherits(server, "AtlasServer"))
        stop("Pass the AtlasServer returned by serve_atlas()")

    viewer <- AtlasViewer$new()
    url    <- paste0(server$url_prefix, "/atlas/?ws_port=", viewer$ws_port)

    if (open) utils::browseURL(url)
    message("Viewer:  ", url)
    message("R comms: ws://localhost:", viewer$ws_port)

    invisible(viewer)
}


# ── AtlasServer ───────────────────────────────────────────────────────────────

#' HTTP server handle returned by [serve_atlas()]
#' @export
AtlasServer <- R6::R6Class("AtlasServer",

    public = list(
        #' @field url_prefix Base URL for the server
        url_prefix = NULL,
        #' @field port       Port the server is listening on
        port       = NULL,

        #' @description Start the npx serve process
        initialize = function(serve_root, port, url_prefix) {
            self$port       <- port
            self$url_prefix <- url_prefix
            private$root    <- serve_root
            private$start_process()
        },

        #' @description Open the viewer (shorthand for launch_atlas(server))
        open = function(open = TRUE) launch_atlas(self, open = open),

        #' @description Check if the HTTP server process is alive
        is_running = function() !is.null(private$proc) && private$proc$is_alive(),

        #' @description Stop the HTTP server process
        stop = function() {
            if (self$is_running()) {
                private$proc$kill()
                message("AtlasServer: stopped")
            }
            invisible(self)
        },

        #' @description Print method
        print = function(...) {
            cat("AtlasServer\n")
            cat("  url:     ", self$url_prefix, "\n")
            cat("  root:    ", private$root, "\n")
            cat("  running: ", self$is_running(), "\n")
            invisible(self)
        }
    ),

    private = list(
        proc = NULL,
        root = NULL,

        start_process = function() {
            private$proc <- processx::process$new(
                command = "npx",
                args    = c("serve", "-p", as.character(self$port), "--cors"),
                wd      = private$root,
                stdout  = "|",
                stderr  = "|",
                cleanup = TRUE   # kill on R session exit
            )
            Sys.sleep(0.8)  # give npx a moment to bind the port
            if (!private$proc$is_alive())
                stop("Failed to start HTTP server. Is npx installed?")
            message("AtlasServer: serving ", private$root,
                    " at ", self$url_prefix)
        }
    )
)


# ── AtlasViewer ───────────────────────────────────────────────────────────────

#' Bidirectional R <-> viewer communication handle returned by [launch_atlas()]
#' @export
AtlasViewer <- R6::R6Class("AtlasViewer",

    public = list(
        #' @field ws_port Port the WebSocket server is listening on
        ws_port = NULL,

        #' @description Start the WebSocket server
        initialize = function() {
            self$ws_port <- .random_port()
            private$start_server()
        },

        #' @description Send a message to the viewer
        #' @param type Message type string (e.g. `"highlight_genes"`)
        #' @param data R object serialized to JSON
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

        #' @description Register a callback for messages from the viewer
        #' @param type     Message type string (e.g. `"annotation"`)
        #' @param callback Function receiving the parsed message data
        on = function(type, callback) {
            private$cbs[[type]] <- callback
            invisible(self)
        },

        #' @description Stop the WebSocket server
        close = function() {
            if (!is.null(private$server)) {
                private$server$stop()
                private$server <- NULL
                message("AtlasViewer: stopped")
            }
            invisible(self)
        },

        #' @description Print method
        print = function(...) {
            cat("AtlasViewer\n")
            cat("  ws_port:   ", self$ws_port, "\n")
            cat("  connected: ", !is.null(private$ws), "\n")
            cat("  handlers:  ", paste(names(private$cbs), collapse = ", "), "\n")
            invisible(self)
        }
    ),

    private = list(
        ws     = NULL,
        server = NULL,
        cbs    = list(),

        start_server = function() {
            priv <- private
            private$server <- httpuv::startServer(
                host = "127.0.0.1",
                port = self$ws_port,
                app  = list(
                    onWSOpen = function(ws) {
                        priv$ws <- ws
                        ws$onMessage(function(binary, msg) {
                            tryCatch({
                                data <- jsonlite::fromJSON(msg, simplifyVector = FALSE)
                                cb   <- priv$cbs[[data$type]]
                                if (!is.null(cb))
                                    later::later(function() cb(data$data), delay = 0)
                            }, error = function(e) {
                                warning("AtlasViewer: bad message: ", e$message)
                            })
                        })
                        message("AtlasViewer: viewer connected")
                    }
                )
            )
        }
    )
)


# ── Helpers ───────────────────────────────────────────────────────────────────

# store@path = .../atera/artifacts/uid/data
# serve_root = dirname × 3 = .../atera
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
    # 1. Installed package: system.file looks in inst/viewer/
    installed <- system.file("viewer", package = "GiottoAtlas")
    if (nzchar(installed)) return(installed)

    # 2. Development via devtools::load_all() — find.package() returns source dir
    pkg_path <- tryCatch(find.package("GiottoAtlas"), error = function(e) "")
    if (nzchar(pkg_path)) {
        path <- file.path(pkg_path, "viewer")
        if (dir.exists(path)) {
            message("Viewer source: ", path)
            return(normalizePath(path))
        }
    }

    stop("Cannot locate viewer files. ",
         "Ensure GiottoAtlas is loaded via devtools::load_all() or installed.")
}

.random_port <- function() sample(49152L:65535L, 1L)

