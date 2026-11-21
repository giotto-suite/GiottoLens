# ── httpuv app ────────────────────────────────────────────────────────────────
#
# URL layout. Everything lives under /lens/<token>/, where <token> is random
# per launch: a path nobody can guess is the access check for the files, since
# httpuv serves static paths on its own thread without asking R (adr/0006).
# The viewer uses page-relative URLs, so a path-prefixing proxy forwards one
# unit. Anything else is a 404.
#
#   /lens/<token>/            viewer bundle, served from the package in place
#   /lens/<token>/ws          the WebSocket
#   /lens/<token>/d/<secret>/ the data, below. <secret> is random and sent
#                             over the WebSocket to the one window that shows
#                             the viewer (adr/0028); it changes when the
#                             viewer moves to another window.
#     session/    manifest.json, the cell table, items/ (temp dir)
#     work/       the viewer's working bundle (adr/0026): metadata/, panels/.
#                 In the project, where others may write, so it goes through
#                 the handler below, which checks real paths on every request.
#     data/<m>/   data store <m>, through the Range handler below. The stores
#                 and images change when another object is loaded (`routes`);
#                 the token does not.
#     files/<m>/  the same files whole, from httpuv's own thread (fast when
#                 the browser is local; adr/0004). That thread follows
#                 symlinks, so a store with links leading out of it goes
#                 through the handler below instead, which checks real paths.
#     image/<k>   image file k, one file per image, through the Range handler
#                 (the viewer reads TIFF tiles by Range). Only the listed
#                 files are served.
#
# The viewer bundle and the data stores are never written to; the project
# folder itself is never served.

.static_headers <- list(
    "Cache-Control"                = "no-cache",
    "Cross-Origin-Opener-Policy"   = "same-origin",
    "Cross-Origin-Embedder-Policy" = "credentialless",
    # httpuv gzips when the browser asks, and fetch() cannot opt out
    "Content-Encoding"             = "identity"
)

# `routes`: environment holding `secret`, the data path segment, `mounts`, the
# data directories (name → path), `images`, the image files (k → path, see
# .image_entries()), and `work`, the working bundle's directory, all
# normalized; read on each request, so a load can change them. The static
# paths of a new secret or a new object's stores are set with .data_paths().
# `session_dir`: directory with manifest.json and metadata/.
# `ws_handlers`: list(open = function(ws), message = function(ws, msg),
#   close = function(ws)); `token`: the per-launch path segment.
# `check_origin`: FALSE behind a proxy that changes the Origin (RStudio Server,
#   Workbench); the token still guards the socket.
.lens_app <- function(viewer_dir, session_dir, routes, token, ws_handlers,
                      check_origin = TRUE) {
    root <- .lens_root(token)
    paths <- c(
        stats::setNames(list(.static_path(viewer_dir, index = TRUE)), root),
        .data_paths(.data_root(root, routes$secret), session_dir, routes$mounts)
    )
    list(
        call = function(req) .data_response(req, routes$mounts,
            .data_root(root, routes$secret), routes$images, routes$work),
        staticPaths = paths,
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

.lens_root <- function(token) paste0("/lens/", token)

# The path the data is served under: `root` is .lens_root()
.data_root <- function(root, secret) paste0(root, "/d/", secret)

# The static paths under `data_root`: session/ and the stores' files/<m> from
# httpuv's own thread, everything else through .data_response(). `linked`:
# per mount, whether .links_outside().
.data_paths <- function(data_root, session_dir, mounts,
                        linked = vapply(mounts, .links_outside, NA)) {
    c(stats::setNames(list(httpuv::excludeStaticPath(), .static_path(session_dir)),
        paste0(data_root, c("", "/session"))),
        .files_paths(data_root, mounts, linked))
}

.static_path <- function(dir, index = FALSE) httpuv::staticPath(dir,
    indexhtml = index, fallthrough = FALSE, headers = .static_headers)

# The files/<m> static paths for normalized store dirs `mounts`; none when the
# cells come from spatial locations alone
.files_paths <- function(root, mounts, linked = vapply(mounts, .links_outside, NA)) {
    files <- Map(function(m, out)
        if (out) httpuv::excludeStaticPath() else .static_path(m), mounts, linked)
    if (length(files)) stats::setNames(files, paste0(root, "/files/", names(mounts)))
}

# TRUE when a symlink under `dir` (a normalized path) resolves outside it
.links_outside <- function(dir) {
    entries <- list.files(dir, recursive = TRUE, all.files = TRUE, full.names = TRUE,
        include.dirs = TRUE, no.. = TRUE)
    links <- entries[nzchar(Sys.readlink(entries))]
    length(links) > 0L &&
        !all(startsWith(normalizePath(links, mustWork = FALSE), paste0(dir, "/")))
}

# A WebSocket is accepted when its path is under this launch's token, and its
# Origin (if a browser sent one) is either local or the server itself.
# The token is the real check; the Origin test only blocks foreign pages
# early. A local proxy (Positron, VS Code) has a loopback Origin (adr/0006).
.ws_allowed <- function(req, token, check_origin = TRUE) {
    if (!startsWith(req$PATH_INFO %||% "", paste0(.lens_root(token), "/"))) return(FALSE)
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

# ── Range-aware file handler ─────────────────────────────────────────────────
#
# httpuv's staticPath ignores Range (always 200 + whole file), which makes the
# viewer download every column of every tile. This handler answers single
# byte ranges with 206. It runs on R's main thread, so requests wait while R
# is busy (adr/0004). `root`: the data path (.data_root()). It also answers
# files/<m>/ for stores not mounted statically (.links_outside()), image/<k>
# for the files in `images`, and work/ for the files under `work`.

.data_response <- function(req, mounts, root, images = list(), work = NULL) {
    # A %00 cannot be decoded into an R string
    path <- tryCatch(utils::URLdecode(req$PATH_INFO %||% ""), error = function(e) "")
    image_prefix <- paste0(root, "/image/")
    if (startsWith(path, image_prefix)) {
        file <- images[[substring(path, nchar(image_prefix) + 1L)]]
        if (is.null(file) || !file.exists(file)) return(.http_status(404L))
        return(.file_response(req, file))
    }
    work_prefix <- paste0(root, "/work/")
    if (startsWith(path, work_prefix)) {
        if (is.null(work)) return(.http_status(404L))
        return(.served_file(req, work, substring(path, nchar(work_prefix) + 1L)))
    }
    m <- NULL
    for (prefix in paste0(root, c("/data/", "/files/"))) {
        if (!startsWith(path, prefix)) next
        rest <- substring(path, nchar(prefix) + 1L)
        m <- regmatches(rest, regexec("^([^/]+)/(.+)$", rest))[[1L]]
    }
    if (!length(m)) return(.http_status(404L))
    root <- mounts[[m[[2L]]]]
    if (is.null(root)) return(.http_status(404L))
    .served_file(req, root, m[[3L]])
}

# File `rel` under directory `root` (normalized), if its real path is inside it
.served_file <- function(req, root, rel) {
    if (grepl("(^|/)\\.\\.?(/|$)", rel) || grepl("\\\\", rel)) return(.http_status(404L))
    file <- file.path(root, rel)
    if (!file.exists(file) || dir.exists(file)) return(.http_status(404L))
    if (!startsWith(normalizePath(file), paste0(root, "/")))
        return(.http_status(404L))
    .file_response(req, file)
}

# One file, whole or a single byte range
.file_response <- function(req, file) {
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
