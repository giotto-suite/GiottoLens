# ── Viewer → R messages ──────────────────────────────────────────────────────

# Bump with PROTOCOL in inst/viewer-src/core/comms.js
.lens_protocol <- 8L

# Message types the viewer sends; anything else arriving on the socket is
# dropped. `on()` callbacks can be registered for the first two. `hello` is
# the only one read from a window that does not show the viewer (adr/0028).
.lens_inbound_types <- c("cell_selection", "annotations_update", "hello",
    "ready", "reply", "client_error", "log", "config", "panel_closed",
    "registration_update", "set_column_type", "ask", "close", "panel_pick",
    "analysis_param", "analysis_labels",
    "analysis_cancel", "analysis_settings", "analysis_region", "analysis_run",
    "analysis_add", "analysis_remove", "analysis_history", "analysis_feature", "analysis_open",
    "preferences_set", "choose_image")
.lens_callback_types <- c("cell_selection", "annotations_update")

# Messages about the object a page shows, ignored from a page that has not
# reloaded since the last set_object() (adr/0017)
.lens_object_types <- c("cell_selection", "annotations_update", "config",
    "panel_closed", "registration_update", "set_column_type", "panel_pick",
    "analysis_param", "analysis_labels",
    "analysis_cancel", "analysis_settings", "analysis_region", "analysis_run",
    "analysis_add", "analysis_remove", "analysis_history", "analysis_feature", "analysis_open", "choose_image")

# `ask` ops about the object a page shows, refused to a page that has not
# reloaded since the last load
.lens_object_ops <- c("catalog", "pull", "item", "cell_ids", "region", "save")

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
            viewer$annotations <- .annotations_from_rows(dat[["annotations"]])
        },
        registration_update = {
            viewer$registration <- .parse_registration(dat)
        }
    )
    invisible(viewer)
}

# Annotations: R shows them as GeoJSON strings named by the annotations'
# names, unique and never empty (the page sees to it). Messages and state.json
# carry rows of {name, geojson}; saves made before names were unique may have
# empty or repeated ones, which get default names.
.annotations_from_rows <- function(rows) {
    if (!length(rows)) return(list())
    str <- function(v) { v <- as.character(unlist(v))[1L]; if (is.na(v)) "" else v }
    stats::setNames(lapply(rows, function(a) str(a[["geojson"]])),
        .annotation_names(vapply(rows, function(a) str(a[["name"]]), "")))
}

.annotations_rows <- function(a) {
    lapply(seq_along(a), function(i) list(name = names(a)[[i]], geojson = a[[i]]))
}

# `nms` with empty and repeated ones (after the first) replaced by
# annotation_<n>, n above any in use; as the page names new shapes
.annotation_names <- function(nms) {
    bad <- !nzchar(nms) | duplicated(nms)
    used <- regmatches(nms[!bad], regexpr("^annotation_[0-9]+$", nms[!bad]))
    n <- max(c(0L, as.integer(sub("^annotation_", "", used))))
    nms[bad] <- paste0("annotation_", n + seq_len(sum(bad)))
    nms
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
