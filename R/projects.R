# ── Projects: opening one, listing its snapshots, recent ones (adr/0019) ─────

# A GiottoDisk project to open, as a gDirSource. Only an existing project:
# opening never creates one, from the page or the console.
.project_source <- function(path, site) {
    if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path))
        stop("[", site, "] `path` must be a directory path", call. = FALSE)
    path <- path.expand(path)
    if (!file.exists(file.path(path, "giottodir.json")))
        stop("[", site, "] not a GiottoDisk project (no giottodir.json): ", path,
            call. = FALSE)
    if (!requireNamespace("GiottoDisk", quietly = TRUE))
        stop("[", site, "] opening a project needs GiottoDisk", call. = FALSE)
    suppressMessages(GiottoDisk::gDirSource(normalizePath(path)))
}

# The live snapshots of `src`, newest first, as the start page lists them,
# with the spatial units and feature types each one's manifest.json records
# (none for a snapshot saved without one)
.project_snapshots <- function(src) {
    info <- GiottoDisk::snapshotInfo(src)
    info <- info[order(info$created, decreasing = TRUE), , drop = FALSE]
    # A snapshot saved before snapshot.json existed has no creator, keep or
    # description: null to the page
    val <- function(v) if (!is.na(v)) v
    lapply(seq_len(nrow(info)), function(i) {
        keys <- .manifest_keys(file.path(src@path, "giottosave", info$tag[[i]],
            "manifest.json"))
        list(
            name        = info$name[[i]],
            tag         = info$tag[[i]],
            created     = val(format(info$created[[i]], "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
            creator     = val(info$creator[[i]]),
            keep        = val(info$keep[[i]]),
            description = val(info$description[[i]]),
            spat_units  = as.list(keys$spat_units),
            feat_types  = as.list(keys$feat_types)
        )
    })
}

# What the info button and object_info() show of snapshot `tag` of `src`,
# read from its sidecars without loading it: snapshot.json (who saved it, why,
# from what) and manifest.json (what the object holds). `save` is the row of
# .lens_saves() for the Lens save open, if any. A snapshot without a manifest
# has NULL `object`, `counts` and `contents`.
.object_info <- function(src, tag, save = NULL) {
    all <- GiottoDisk::snapshotInfo(src, deleted = TRUE)
    s <- all[all$tag == tag, , drop = FALSE]
    if (!nrow(s)) stop("[LensViewer] no snapshot '", tag, "' in ", src@path, call. = FALSE)
    val <- function(v) if (length(v) && !is.na(v[[1L]])) v[[1L]]
    iso <- function(t) val(format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
    # A field GiottoDisk does not have (an owner, say) is kept in `extra`
    extra <- s$extra[[1L]]
    text <- function(v) if (is.atomic(v)) paste(v, collapse = ", ") else
        as.character(jsonlite::toJSON(v, auto_unbox = TRUE))
    parents <- unlist(s$parents[[1L]])
    parent_names <- vapply(parents, function(p) {
        n <- all$name[all$tag == p]
        if (length(n)) n[[1L]] else p
    }, "", USE.NAMES = FALSE)
    m <- file.path(src@path, "giottosave", tag, "manifest.json")
    m <- if (file.exists(m)) jsonlite::fromJSON(m, simplifyVector = FALSE)
    list(
        project  = src@path,
        snapshot = list(
            name = s$name[[1L]], tag = tag, created = iso(s$created),
            creator = val(s$creator), owner = if (!is.null(extra$owner)) text(extra$owner),
            keep = val(s$keep), description = val(s$description),
            labels = as.list(unlist(s$labels[[1L]])), parents = as.list(parent_names),
            session = val(s$session), object = val(s$object),
            extra = lapply(extra[setdiff(names(extra), "owner")], text)),
        save = if (!is.null(save) && nrow(save)) list(
            name = save$name[[1L]], updated = iso(save$updated),
            description = val(save$description),
            labels = if (nzchar(save$labels[[1L]])) as.list(strsplit(save$labels[[1L]], ", ")[[1L]])
                else list()),
        object = if (!is.null(m)) list(class = m$object$class, uid = m$object$uid,
            written_by = m$generated_by, history_steps = m$summary$n_history_steps),
        counts = if (!is.null(m)) list(cells = m$summary$n_cells, features = m$summary$n_features),
        contents = if (!is.null(m)) .manifest_contents(m$slots)
    )
}

# A manifest's slots for reading: slot -> list of groups {on, items}, `on`
# the keys a group's records share ("cell / rna", "" for none), each item a
# {name, detail}. Metadata items are its columns, the ID column left out, and
# a record with no other column is left out. cell_ID and feat_ID are in the
# counts instead.
.manifest_contents <- function(slots) {
    item <- function(name, detail = NULL) list(name = name, detail = detail)
    one <- function(slot, r) {
        k <- r$keys
        if (slot %in% c("cell_metadata", "feat_metadata")) {
            cols <- setdiff(names(r$columns), c("cell_ID", "feat_ID"))
            if (!length(cols)) return(NULL)
            return(list(on = paste(unlist(k), collapse = " / "),
                items = lapply(cols, function(c) item(c, r$columns[[c]]$dtype))))
        }
        on <- unlist(k[setdiff(names(k), c("name", "reduction_method", "nn_type", "reduction"))])
        name <- k$name %||% k$feat_type
        detail <- switch(slot,
            expression = r$dtype,
            spatial_info = if (length(r$overlaps_computed))
                paste("overlaps:", paste(unlist(r$overlaps_computed), collapse = ", ")),
            feat_info = if (!identical(r$class, "giottoPoints")) r$class,
            dimension_reduction = paste(c(
                if (!identical(k$reduction_method, k$name)) k$reduction_method,
                if (identical(k$reduction, "feats")) "over features"), collapse = ", "),
            nn_network = k$nn_type,
            images = r$class,
            NULL)
        if (identical(detail, "")) detail <- NULL
        if (slot == "feat_info") on <- NULL
        list(on = paste(on, collapse = " / "), items = list(item(name, detail)))
    }
    slots <- slots[setdiff(names(slots), c("cell_ID", "feat_ID"))]
    out <- lapply(names(slots), function(slot) {
        recs <- Filter(Negate(is.null), lapply(slots[[slot]], function(r) one(slot, r)))
        on <- vapply(recs, `[[`, "", "on")
        lapply(unique(on), function(g) list(on = g,
            items = do.call(c, lapply(recs[on == g], `[[`, "items"))))
    })
    names(out) <- names(slots)
    Filter(length, out)
}

# Spatial units with cells (polygons or spatial locations) and feature types
# with points, from a snapshot's manifest.json; NULL fields if it has none.
# "cell" / "rna" come first when present: the page's pickers open on the first.
.manifest_keys <- function(file) {
    if (!file.exists(file)) return(list())
    m <- jsonlite::fromJSON(file, simplifyVector = FALSE)$slots
    key <- function(slot, k) unique(unlist(lapply(m[[slot]], function(r) r$keys[[k]])))
    first <- function(have, lead) if (length(have)) union(intersect(lead, have), have)
    list(
        spat_units = first(unique(c(key("spatial_info", "name"),
            key("spatial_locs", "spat_unit"))), "cell"),
        feat_types = first(key("feat_info", "feat_type"), "rna")
    )
}

# The spatial unit and feature type to show of `x` when not given (NA): the
# first of `prefer`, then "cell" / "rna", then the object's defaults (its active
# ones, else those of its first expression), that it has cells or points for;
# else its first, else NULL. Given ones (NULL included) are kept. "cell" / "rna"
# lead the object's active ones because the start page, which reads only the
# manifest, cannot see them: both ways of opening a snapshot agree.
.default_keys <- function(x, spat_unit = NA, feat_type = NA, prefer_unit = NULL,
                          prefer_feat = NULL) {
    auto <- function(key) is.atomic(key) && length(key) == 1L && is.na(key)
    pick <- function(have, prefer) {
        hit <- intersect(prefer, have)
        if (length(hit)) hit[[1L]] else if (length(have)) have[[1L]]
    }
    quiet <- function(expr) tryCatch(suppressWarnings(expr), error = function(e) NULL)
    if (auto(spat_unit))
        spat_unit <- pick(union(names(x@spatial_info), names(x@spatial_locs)),
            c(prefer_unit, "cell", quiet(GiottoClass::set_default_spat_unit(gobject = x))))
    if (auto(feat_type))
        feat_type <- pick(names(x@feat_info), c(prefer_feat, "rna",
            quiet(GiottoClass::set_default_feat_type(gobject = x, spat_unit = spat_unit))))
    list(spat_unit = spat_unit, feat_type = feat_type)
}

# ── Recent projects ──────────────────────────────────────────────────────────
# One list per user, newest first, in R's user data directory (or
# getOption("GiottoLens.recent_projects"), a file path)

.lens_recent_max <- 10L

.recent_file <- function() {
    getOption("GiottoLens.recent_projects",
        file.path(tools::R_user_dir("GiottoLens", "data"), "recent_projects.json"))
}

# data.frame of path, opened (ISO 8601 UTC)
.recent_projects <- function(file = .recent_file()) {
    r <- if (file.exists(file)) jsonlite::fromJSON(file)
    if (!is.data.frame(r) || !nrow(r))
        return(data.frame(path = character(), opened = character()))
    r[c("path", "opened")]
}

.add_recent <- function(path, file = .recent_file()) {
    path <- normalizePath(path)
    r <- .recent_projects(file)
    r <- rbind(data.frame(path = path,
        opened = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")), r[r$path != path, ])
    dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(utils::head(r, .lens_recent_max), file)
    invisible(path)
}

# ── Folder dialog ────────────────────────────────────────────────────────────
# The IDE's, through rstudioapi: RStudio has one, Positron not yet. Elsewhere
# the page offers recent projects and a path box only.

.can_browse <- function() {
    interactive() && requireNamespace("rstudioapi", quietly = TRUE) &&
        rstudioapi::isAvailable() && rstudioapi::hasFun("selectDirectory")
}

.browse_folder <- function() {
    if (!.can_browse()) stop("no folder dialog in this R session", call. = FALSE)
    rstudioapi::selectDirectory(caption = "Open a GiottoDisk project")
}
