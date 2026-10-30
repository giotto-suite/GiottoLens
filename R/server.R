# ── httpuv app ────────────────────────────────────────────────────────────────
#
# URL layout (everything under /lens/ so a path-prefixing proxy can forward it
# as one unit, and the viewer can use page-relative URLs):
#
#   /lens/            viewer bundle, served from the package in place
#   /lens/session/    this viewer's manifest.json and metadata/ (temp dir)
#   /lens/data/<m>/   data store <m>, through the Range handler below
#   /lens/files/<m>/  the same files whole, from httpuv's own thread (fast
#                     when the browser is local; see data/parquet.ts)
#   WebSocket         any path; needs the per-launch token
#
# The viewer bundle and the data stores are never written to.

.static_headers <- list(
    "Cache-Control"                = "no-cache",
    "Cross-Origin-Opener-Policy"   = "same-origin",
    "Cross-Origin-Embedder-Policy" = "credentialless",
    # httpuv gzips when the browser asks, and fetch() cannot opt out
    "Content-Encoding"             = "identity"
)

# `mounts`: named list of data directories (name → path).
# `session_dir`: directory with manifest.json and metadata/.
# `ws_handlers`: list(open = function(ws), message = function(ws, msg),
#   close = function(ws)); `token`: required on the WebSocket URL.
# `check_origin`: FALSE behind a proxy that changes the Origin (RStudio Server,
#   Workbench); the token still guards the socket.
.lens_app <- function(viewer_dir, session_dir, mounts, token, ws_handlers,
                      check_origin = TRUE) {
    mounts <- lapply(mounts, normalizePath, mustWork = TRUE)
    files <- stats::setNames(
        lapply(mounts, httpuv::staticPath, indexhtml = FALSE, fallthrough = FALSE,
            headers = .static_headers),
        paste0("/lens/files/", names(mounts)))
    list(
        call = function(req) .data_response(req, mounts),
        staticPaths = c(list(
            "/lens" = httpuv::staticPath(viewer_dir,
                indexhtml = TRUE, fallthrough = FALSE,
                headers = .static_headers),
            "/lens/session" = httpuv::staticPath(session_dir,
                indexhtml = FALSE, fallthrough = FALSE,
                headers = .static_headers),
            "/lens/data" = httpuv::excludeStaticPath()
        ), files),
        onWSOpen = function(ws) {
            if (!.ws_allowed(ws$request, token, check_origin)) {
                ws$close()
                return(invisible())
            }
            ws_handlers$open(ws)
            ws$onMessage(function(binary, msg) {
                if (!binary) ws_handlers$message(ws, msg)
            })
            ws$onClose(function() ws_handlers$close(ws))
        }
    )
}

# A WebSocket is accepted when it carries this launch's token, and its
# Origin (if a browser sent one) is either local or the server itself.
# The token is the real check; the Origin test only blocks foreign pages
# early. A local proxy (Positron, VS Code) has a loopback Origin.
.ws_allowed <- function(req, token, check_origin = TRUE) {
    query <- .parse_query(req$QUERY_STRING)
    if (!identical(query[["token"]], token)) return(FALSE)
    !check_origin || .origin_allowed(req$HTTP_ORIGIN, req$HTTP_HOST)
}

.origin_allowed <- function(origin, host) {
    if (is.null(origin) || !nzchar(origin)) return(TRUE) # not a browser
    m <- regmatches(origin, regexec("^https?://([^/]+)$", origin))[[1L]]
    if (!length(m)) return(FALSE)
    origin_host <- tolower(m[[2L]])
    if (!is.null(host) && identical(origin_host, tolower(host))) return(TRUE)
    hostname <- sub(":[0-9]+$", "", origin_host)
    hostname %in% c("localhost", "127.0.0.1", "[::1]") ||
        origin_host %in% tolower(getOption("GiottoLens.allowed_origins", character()))
}

.parse_query <- function(qs) {
    qs <- sub("^\\?", "", qs %||% "")
    if (!nzchar(qs)) return(list())
    kv  <- strsplit(strsplit(qs, "&", fixed = TRUE)[[1L]], "=", fixed = TRUE)
    out <- lapply(kv, function(p) utils::URLdecode(paste(p[-1L], collapse = "=")))
    stats::setNames(out, vapply(kv, `[[`, "", 1L))
}

# ── Range-aware file handler ─────────────────────────────────────────────────
#
# httpuv's staticPath ignores Range (always 200 + whole file), which makes the
# viewer download every column of every tile. This handler answers single
# byte ranges with 206. It runs on R's main thread, so requests wait while R
# is busy; see vignettes/articles/data_delivery.md.

.data_response <- function(req, mounts) {
    path <- utils::URLdecode(req$PATH_INFO %||% "")
    m <- regmatches(path, regexec("^/lens/data/([^/]+)/(.+)$", path))[[1L]]
    if (!length(m)) return(.http_status(404L))
    root <- mounts[[m[[2L]]]]
    rel  <- m[[3L]]
    if (is.null(root) || grepl("(^|/)\\.\\.?(/|$)", rel) || grepl("\\\\", rel))
        return(.http_status(404L))
    file <- file.path(root, rel)
    if (!file.exists(file) || dir.exists(file)) return(.http_status(404L))
    if (!startsWith(normalizePath(file), paste0(root, "/")))
        return(.http_status(404L))

    method <- req$REQUEST_METHOD %||% "GET"
    if (!method %in% c("GET", "HEAD")) return(.http_status(405L))
    size    <- file.size(file)
    headers <- list(
        "Content-Type"     = "application/octet-stream",
        "Accept-Ranges"    = "bytes",
        "Cache-Control"    = "no-cache",
        "Content-Encoding" = "identity"
    )
    range <- .parse_range(req$HTTP_RANGE, size)
    if (is.null(range)) {
        if (method == "HEAD")
            return(list(status = 200L,
                headers = c(headers, "Content-Length" = format(size, scientific = FALSE)),
                body = raw(0)))
        return(list(status = 200L, headers = headers, body = c(file = file)))
    }
    if (identical(range, NA)) {
        return(list(status = 416L,
            headers = c(headers, "Content-Range" = sprintf("bytes */%.0f", size)),
            body = raw(0)))
    }
    len <- range[[2L]] - range[[1L]] + 1
    body <- if (method == "HEAD") raw(0) else {
        con <- file(file, "rb")
        on.exit(close(con), add = TRUE)
        seek(con, range[[1L]])
        readBin(con, "raw", n = len)
    }
    list(status = 206L,
        headers = c(headers, "Content-Range" =
            sprintf("bytes %.0f-%.0f/%.0f", range[[1L]], range[[2L]], size)),
        body = body)
}

# Returns c(start, end) (inclusive), NULL for no/unsupported Range (serve the
# whole file), or NA when the range cannot be satisfied.
.parse_range <- function(header, size) {
    if (is.null(header) || !nzchar(header)) return(NULL)
    m <- regmatches(header, regexec("^bytes=([0-9]*)-([0-9]*)$", header))[[1L]]
    if (!length(m) || (!nzchar(m[[2L]]) && !nzchar(m[[3L]]))) return(NULL)
    if (!nzchar(m[[2L]])) {
        n <- as.numeric(m[[3L]])
        if (n == 0) return(NA)
        return(c(max(0, size - n), size - 1))
    }
    start <- as.numeric(m[[2L]])
    end   <- if (nzchar(m[[3L]])) min(as.numeric(m[[3L]]), size - 1) else size - 1
    if (start >= size || start > end) return(NA)
    c(start, end)
}

.http_status <- function(status) {
    list(status = status, headers = list("Content-Type" = "text/plain"),
        body = switch(as.character(status),
            "404" = "Not found", "405" = "Method not allowed", "error"))
}
