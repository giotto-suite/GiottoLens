# ── Lens saves: bundles in the project (adr/0026) ───────────────────────────
#
# A viewer keeps its work in a working bundle, <project>/lens/session-<session
# id>/, written as the work changes and served to the page under work/. A save
# copies it to <project>/lens/<name>.<id>/. Each bundle holds:
#
#   bundle.json     what it was made on: the snapshot's tag, the object, the
#                   spatial unit and feature type, a fingerprint of the cells,
#                   and for a save its name, description and labels
#   state.json      the work: rules, annotations, registration, saved selections,
#                   pushed panels, metadata columns and their types, added
#                   images, comparisons
#   config.json     the page's config, as it sent it
#   metadata/ panels/ de/   the files state.json points to
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

# File `f` of bundle `dir`, or NULL unless it is a regular file inside it.
# Others may write to the project: a link there must not bring a file from
# elsewhere into this viewer's working bundle, where they could read it.
.bundle_file <- function(dir, f) {
    path <- file.path(dir, f)
    if (!file.exists(path) || dir.exists(path) || nzchar(Sys.readlink(path))) return(NULL)
    if (!startsWith(normalizePath(path), paste0(normalizePath(dir), "/"))) return(NULL)
    path
}

.read_bundle_json <- function(path) {
    path <- .bundle_file(dirname(path), basename(path))
    if (is.null(path)) return(NULL)
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

# A running viewer rewrites its working bundle's bundle.json at least this
# often (seconds), so a viewer on another machine can tell it still runs
# (adr/0033)
.heartbeat_s <- 30

# Whether the viewer that wrote working bundle `dir` (`b` its bundle.json)
# still runs: on this machine, one of this process's running viewers or a
# process still running; on another, one whose bundle.json was written less
# than four heartbeats ago. The file's time comes from the file system, the
# margin covers clocks a little apart.
.session_live <- function(b, dir) {
    if (identical(b$host, Sys.info()[["nodename"]]) && is.numeric(b$pid)) {
        if (b$pid == Sys.getpid())
            return(any(vapply(as.list(.lens_registry), function(v)
                identical(get("private", v$.__enclos_env__)$session_id, b$session), NA)))
        return(isTRUE(tryCatch(tools::pskill(b$pid, 0L), error = function(e) FALSE,
            warning = function(w) FALSE)))
    }
    age <- difftime(Sys.time(), file.mtime(file.path(dir, "bundle.json")), units = "secs")
    isTRUE(as.numeric(age) < 4 * .heartbeat_s)
}

# The bundles in project `src`: saves, and with `sessions` the working bundles
# of viewers that have ended. A data.frame with name (what open_save() takes),
# kind ("save" or "session"), created, updated, snapshot (its tag),
# description, labels, user and host (who wrote it, where), live (for
# sessions) and dir.
.lens_saves <- function(src, sessions = FALSE) {
    # A link is never a bundle (adr/0033): others may write to the project, and
    # opening, deleting or overwriting a link named like one would reach a
    # folder elsewhere
    dirs <- list.dirs(.lens_dir(src), recursive = FALSE)
    dirs <- dirs[!nzchar(Sys.readlink(dirs))]
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
            user = as.character(b$user %||% NA), host = as.character(b$host %||% NA),
            live = if (work) .session_live(b, d) else NA, dir = d)
    })
    out <- do.call(rbind, Filter(Negate(is.null), rows))
    if (is.null(out)) out <- data.frame(name = character(), kind = character(),
        created = numeric(), updated = numeric(), snapshot = character(),
        description = character(), labels = character(), user = character(),
        host = character(), live = logical(), dir = character())
    if (!sessions) out <- out[out$kind == "save", , drop = FALSE]
    out$created <- .POSIXct(out$created)
    out$updated <- .POSIXct(out$updated)
    out <- out[order(out$updated, decreasing = TRUE), , drop = FALSE]
    rownames(out) <- NULL
    out
}

# The bundle `name` in project `src`, one R lists: a save's name, or a
# working bundle's folder name. Never a path taken as given. `all`: the
# listing, when several are looked up.
.find_save <- function(src, name, site, all = .lens_saves(src, sessions = TRUE)) {
    if (!is.character(name) || length(name) != 1L || is.na(name))
        stop("[", site, "] `name` must be the name of a save", call. = FALSE)
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
        vapply(state$de %||% list(), function(d) one(d$file), ""))
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
    files <- c("state.json", if (!is.null(.bundle_file(from, "config.json"))) "config.json",
        .bundle_files(state))
    for (f in unique(files)) {
        src <- .bundle_file(from, f)
        dest <- file.path(stage, f)
        dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
        if (is.null(src) || !file.copy(src, dest))
            stop("[LensViewer] could not copy ", f, " into the save", call. = FALSE)
    }
    .write_json_atomic(bundle, file.path(stage, "bundle.json"))
    if (!file.rename(stage, to))
        stop("[LensViewer] could not write the save ", to, call. = FALSE)
    invisible(to)
}

# The saves of `src` as the start page lists them, newest first, and the work
# viewers that ended left there; `current`: the save shown, if any. A save
# whose snapshot was deleted has `snapshot` null; `mine`: not written by
# another user (one written before bundles named their user counts), a label
# for browsing, not access control (adr/0026).
.project_saves <- function(src, current = NULL) {
    s <- .lens_saves(src, sessions = TRUE)
    s <- s[s$kind == "save" | !s$live, , drop = FALSE]
    me <- Sys.info()[["user"]]
    snaps <- GiottoDisk::snapshotInfo(src)
    iso <- function(t) if (!is.na(t)) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
    lapply(seq_len(nrow(s)), function(i) {
        snap <- snaps$name[snaps$tag == s$snapshot[[i]]]
        list(name = s$name[[i]], kind = s$kind[[i]], updated = iso(s$updated[[i]]),
            description = if (!is.na(s$description[[i]])) s$description[[i]],
            labels = if (nzchar(s$labels[[i]])) as.list(strsplit(s$labels[[i]], ", ")[[1L]]) else list(),
            snapshot = if (length(snap)) snap[[1L]],
            user = if (!is.na(s$user[[i]])) s$user[[i]], host = if (!is.na(s$host[[i]])) s$host[[i]],
            mine = is.na(s$user[[i]]) || identical(s$user[[i]], me),
            current = identical(basename(s$dir[[i]]), current))
    })
}
