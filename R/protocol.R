# ── Viewer → R messages ──────────────────────────────────────────────────────

# Bump with PROTOCOL in inst/viewer-src/core/comms.js
.lens_protocol <- 2L

# Message types the viewer sends; anything else arriving on the socket is
# dropped. `on()` callbacks can be registered for the first two.
.lens_inbound_types <- c("cell_selection", "annotations_update",
    "ready", "reply", "client_error", "log")
.lens_callback_types <- c("cell_selection", "annotations_update")

# Parse and validate one WebSocket text frame.
# Returns list(type, data), or NULL with a warning when the frame is invalid.
.parse_ws_message <- function(msg) {
    parsed <- tryCatch(
        jsonlite::fromJSON(msg, simplifyVector = FALSE),
        error = function(e) NULL
    )
    type <- if (is.list(parsed)) parsed[["type"]]
    if (!is.character(type) || length(type) != 1L ||
        !type %in% .lens_inbound_types) {
        warning("[LensViewer] dropped an invalid message from the viewer",
            call. = FALSE)
        return(NULL)
    }
    list(type = type, id = parsed[["id"]], data = parsed[["data"]],
        error = parsed[["error"]])
}

# Apply a parsed message to the viewer's public fields. `viewer` is anything
# with `$<-` (the LensViewer, or an environment in tests). `cell_ids` maps the
# viewer's cell indices (0-based) to IDs.
.handle_ws_message <- function(viewer, msg, cell_ids = NULL) {
    dat <- msg$data
    switch(msg$type,
        cell_selection = {
            idx <- .decode_mask(dat[["mask"]], length(cell_ids))
            viewer$selection <- if (length(idx)) cell_ids[idx] else character(0)
            viewer$selection_rules <- dat[["rules"]]
        },
        annotations_update = {
            viewer$annotations <- lapply(dat[["annotations"]], function(a) list(
                id      = as.character(a[["id"]] %||% ""),
                name    = as.character(a[["name"]] %||% ""),
                type    = as.character(a[["type"]] %||% ""),
                geojson = as.character(a[["geojson"]] %||% "")
            ))
        }
    )
    invisible(viewer)
}

# ── Selection masks ──────────────────────────────────────────────────────────
#
# Selections cross the socket as a bitmask over the viewer's cell order,
# base64 encoded: bit i (least significant first within each byte) is cell i.
# Its size is N/8 bytes whatever the selection, unlike an ID list.

# Returns 1-based positions of set bits among the first `n`
.decode_mask <- function(b64, n) {
    if (is.null(b64) || !nzchar(b64) || !n) return(integer(0))
    bits <- rawToBits(jsonlite::base64_dec(b64))
    if (length(bits) < n)
        stop("[LensViewer] selection mask is shorter than the cell count", call. = FALSE)
    which(as.logical(bits[seq_len(n)]))
}

# `idx`: 1-based positions to set among `n`
.encode_mask <- function(idx, n) {
    bits <- logical(ceiling(n / 8) * 8)
    bits[idx] <- TRUE
    jsonlite::base64_enc(packBits(bits, "raw"))
}

# ── R → viewer messages ──────────────────────────────────────────────────────

.encode_ws_message <- function(type, data = NULL, id = NULL) {
    msg <- list(type = type, data = data)
    if (!is.null(id)) msg$id <- id
    jsonlite::toJSON(msg, auto_unbox = TRUE, null = "null", digits = NA)
}
