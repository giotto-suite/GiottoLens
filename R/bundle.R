# ── Lens saves: bundles in the project (adr/0026) ───────────────────────────
#
# A viewer keeps its work in a working bundle, <project>/lens/session-<session
# id>/, written as the work changes and served to the page under work/. A save
# copies it to <project>/lens/<name>.<id>/. Each bundle holds:
#
#   bundle.json     what it was made on: the snapshot's tag, the object, the
#                   spatial unit and feature type, a fingerprint of the cells,
#                   and for a save its name, description and labels
#   state.json      the work: rules, annotations, registration, regions,
#                   pushed panels, metadata columns and their types, added
#                   images, comparisons
#   config.json     the page's config, as it sent it
#   metadata/ panels/ de/ regions.parquet   the files state.json points to
#
# JSON and parquet only: nothing in a bundle is deserialized as R objects.

.bundle_format <- 1L

.lens_dir <- function(src) file.path(src@path, "lens")

.work_name <- function(session_id) paste0("session-", session_id)

# Save names: a save's folder is `<name>.<id>`, so no dots; `session-` names
# the working bundles
.check_save_name <- function(name, site) {
    if (!is.character(name) || length(name) != 1L || is.na(name) ||
            !grepl("^[A-Za-z0-9_-]{1,64}$", name))
        stop("[", site, "] `name` must be one string of up to 64 letters, digits, '_' or '-'",
            call. = FALSE)
    if (startsWith(name, "session-"))
        stop("[", site, "] names starting with 'session-' are the viewers' working bundles",
            call. = FALSE)
    name
}

# Written next to `path` and renamed over it, so a reader never sees half a file
.write_text_atomic <- function(text, path) {
    tmp <- tempfile(".tmp", tmpdir = dirname(path))
    writeLines(text, tmp, useBytes = TRUE)
    if (!file.rename(tmp, path)) {
        unlink(tmp)
        stop("[LensViewer] could not write ", path, call. = FALSE)
    }
    invisible(path)
}

.bundle_json <- function(x) jsonlite::toJSON(x, auto_unbox = TRUE, digits = NA, null = "null")

.write_json_atomic <- function(x, path) .write_text_atomic(.bundle_json(x), path)

.read_bundle_json <- function(path) {
    if (!file.exists(path)) return(NULL)
    tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
}

# An md5 of strings, one per line
.strings_md5 <- function(x) {
    tmp <- tempfile()
    on.exit(unlink(tmp), add = TRUE)
    writeLines(enc2utf8(as.character(x)), tmp, useBytes = TRUE)
    unname(tools::md5sum(tmp))
}

# Which cells a bundle's positional rules (`ids` masks) refer to
.cells_fingerprint <- function(cell_ids) list(n = length(cell_ids), md5 = .strings_md5(cell_ids))

# Whether a rule names cells by position, itself or in a union or intersection
.rule_has_ids <- function(rule) {
    if (identical(rule$kind, "ids")) return(TRUE)
    any(vapply(rule$params$parts %||% list(), .rule_has_ids, NA))
}

# Whether the viewer that wrote a working bundle still runs: one of this
# process's running viewers, or a process still running on this machine. NA
# when it ran on another machine.
.session_live <- function(b) {
    if (!identical(b$host, Sys.info()[["nodename"]]) || !is.numeric(b$pid)) return(NA)
    if (b$pid == Sys.getpid())
        return(any(vapply(as.list(.lens_registry), function(v)
            identical(get("private", v$.__enclos_env__)$session_id, b$session), NA)))
    isTRUE(tryCatch(tools::pskill(b$pid, 0L), error = function(e) FALSE, warning = function(w) FALSE))
}

# The bundles in project `src`: saves, and with `sessions` the working bundles
# of viewers that have ended. A data.frame with name (what open_save() takes),
# kind ("save" or "session"), created, updated, snapshot (its tag),
# description, labels, live (for sessions) and dir.
.lens_saves <- function(src, sessions = FALSE) {
    dirs <- list.dirs(.lens_dir(src), recursive = FALSE)
    rows <- lapply(dirs, function(d) {
        b <- .read_bundle_json(file.path(d, "bundle.json"))
        if (is.null(b) || !identical(as.integer(b$format), .bundle_format)) return(NULL)
        base <- basename(d)
        save <- identical(b$kind, "save") && identical(base, paste0(b$name, ".", b$id))
        work <- identical(b$kind, "session") && identical(base, .work_name(b$session))
        if (!save && !work) return(NULL)
        data.frame(name = if (save) b$name else base, kind = b$kind,
            created = as.numeric(b$created %||% NA), updated = as.numeric(b$updated %||% NA),
            snapshot = as.character(b$snapshot %||% NA),
            description = as.character(b$description %||% NA),
            labels = paste(unlist(b$labels), collapse = ", "),
            live = if (work) .session_live(b) else NA, dir = d)
    })
    out <- do.call(rbind, Filter(Negate(is.null), rows))
    if (is.null(out)) out <- data.frame(name = character(), kind = character(),
        created = numeric(), updated = numeric(), snapshot = character(),
        description = character(), labels = character(), live = logical(), dir = character())
    if (!sessions) out <- out[out$kind == "save", , drop = FALSE]
    out$created <- .POSIXct(out$created)
    out$updated <- .POSIXct(out$updated)
    out <- out[order(out$updated, decreasing = TRUE), , drop = FALSE]
    rownames(out) <- NULL
    out
}

# The bundle `name` in project `src`, one R lists: a save's name, or a
# working bundle's folder name. Never a path taken as given.
.find_save <- function(src, name, site) {
    if (!is.character(name) || length(name) != 1L || is.na(name))
        stop("[", site, "] `name` must be the name of a save", call. = FALSE)
    all <- .lens_saves(src, sessions = TRUE)
    hit <- all[all$name == name, , drop = FALSE]
    if (!nrow(hit)) {
        saves <- all$name[all$kind == "save"]
        stop("[", site, "] no save '", name, "' in ", src@path, "; it has: ",
            if (length(saves)) paste(saves, collapse = ", ") else "none", call. = FALSE)
    }
    hit[1L, , drop = FALSE]
}

# The files of bundle `dir` that `state` points to, relative to it
.bundle_files <- function(state) {
    one <- function(u) if (is.character(u) && length(u) == 1L) sub("^work/", "", u) else ""
    files <- c(vapply(state$meta$columns %||% list(), function(cl) one(cl$url), ""),
        vapply(state$pushed %||% list(), function(p) one(p$data_url), ""),
        vapply(state$de %||% list(), function(d) one(d$file), ""),
        if (isTRUE(state$regions)) "regions.parquet")
    files[nzchar(files) & !grepl("(^|/)\\.\\.?(/|$)|\\\\|^/", files)]
}

# Copy bundle `from` (its bundle.json, state.json, config.json and the files
# state.json points to) into a new folder `to`, written next to it and
# renamed into place. `bundle` replaces its bundle.json.
.copy_bundle <- function(from, to, bundle) {
    stage <- file.path(dirname(to), paste0(".stage-", .rand_id(8L)))
    dir.create(stage, recursive = TRUE)
    on.exit(unlink(stage, recursive = TRUE), add = TRUE)
    state <- .read_bundle_json(file.path(from, "state.json")) %||% list()
    files <- c("state.json", if (file.exists(file.path(from, "config.json"))) "config.json",
        .bundle_files(state))
    for (f in unique(files)) {
        dest <- file.path(stage, f)
        dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
        if (!file.copy(file.path(from, f), dest))
            stop("[LensViewer] could not copy ", f, " into the save", call. = FALSE)
    }
    .write_json_atomic(bundle, file.path(stage, "bundle.json"))
    if (!file.rename(stage, to))
        stop("[LensViewer] could not write the save ", to, call. = FALSE)
    invisible(to)
}

# The saves of `src` as the start page lists them, newest first, and the work
# viewers that ended left there; `current`: the save shown, if any. A save
# whose snapshot was deleted has `snapshot` null.
.project_saves <- function(src, current = NULL) {
    s <- .lens_saves(src, sessions = TRUE)
    s <- s[s$kind == "save" | !(s$live %in% TRUE), , drop = FALSE]
    snaps <- GiottoDisk::snapshotInfo(src)
    iso <- function(t) if (!is.na(t)) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    lapply(seq_len(nrow(s)), function(i) {
        snap <- snaps$name[snaps$tag == s$snapshot[[i]]]
        list(name = s$name[[i]], kind = s$kind[[i]], updated = iso(s$updated[[i]]),
            description = if (!is.na(s$description[[i]])) s$description[[i]],
            labels = if (nzchar(s$labels[[i]])) as.list(strsplit(s$labels[[i]], ", ")[[1L]]) else list(),
            snapshot = if (length(snap)) snap[[1L]],
            current = identical(basename(s$dir[[i]]), current))
    })
}
