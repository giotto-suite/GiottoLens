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

# Spatial units with cells (polygons or spatial locations) and feature types
# with points, from a snapshot's manifest.json; NULL fields if it has none
.manifest_keys <- function(file) {
    if (!file.exists(file)) return(list())
    m <- jsonlite::fromJSON(file, simplifyVector = FALSE)$slots
    key <- function(slot, k) unique(unlist(lapply(m[[slot]], function(r) r$keys[[k]])))
    list(
        spat_units = unique(c(key("spatial_info", "name"), key("spatial_locs", "spat_unit"))),
        feat_types = key("feat_info", "feat_type")
    )
}

# The spatial unit and feature type to show of `x` when not given (NA): the
# first of `prefer`, then the object's defaults (its active ones, else those of
# its first expression), then "cell" / "rna", that it has cells or points for;
# else its first, else NULL. Given ones (NULL included) are kept.
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
            c(prefer_unit, quiet(GiottoClass::set_default_spat_unit(gobject = x)), "cell"))
    if (auto(feat_type))
        feat_type <- pick(names(x@feat_info), c(prefer_feat,
            quiet(GiottoClass::set_default_feat_type(gobject = x, spat_unit = spat_unit)), "rna"))
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
