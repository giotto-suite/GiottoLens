# ── Preferences ──────────────────────────────────────────────────────────────
#
# Defaults for every viewer, saved per user in a JSON file. The file holds
# only the preferences that were set; the others take the built-in default
# of the installed GiottoLens. Order: built-in default < preference < launch
# argument or R option < change made in the viewer.

# Built-in defaults and what each preference takes: `type` is "choice"
# (one of `choices`), "number" (between `min` and `max`, whole with
# `integer`), "color" ("#rrggbb") or "text"
.lens_pref_spec <- function() list(
    seq_palette = list(type = "choice", default = "viridis",
        choices = c("viridis", "magma", "inferno", "plasma", "cividis", "turbo", "gray",
            "blue-red")),
    div_palette = list(type = "choice", default = "blue-white-red",
        choices = c("blue-white-red", "RdBu", "PuOr", "PRGn")),
    scale_style = list(type = "choice", default = "divergent",
        choices = c("divergent", "sequential")),
    gene_style = list(type = "choice", default = "default",
        choices = c("default", "divergent", "sequential")),
    cat_palette = list(type = "choice", default = "default",
        choices = c("default", "vivid", "okabe_ito")),
    tx_palette = list(type = "choice", default = "default", choices = c("default", "vivid")),
    background = list(type = "color", default = "#0d1117"),
    outline_color = list(type = "color", default = "#000000"),
    selection_color = list(type = "color", default = "#ffdc32"),
    outline_width = list(type = "number", default = 1, min = 0, max = 10),
    outline_opacity = list(type = "number", default = 0.8, min = 0, max = 1),
    fill_opacity = list(type = "number", default = 0.9, min = 0, max = 1),
    expr_values = list(type = "text", default = "normalized"),
    de_values = list(type = "text", default = "normalized"),
    color_by = list(type = "text", default = ""),
    threads = list(type = "number", default = 4L, min = 1, max = 256, integer = TRUE),
    history = list(type = "number", default = 10L, min = 1, max = 1000, integer = TRUE),
    network_dir = list(type = "text", default = ""),
    import_dir = list(type = "text", default = "")
)

# The preferences file: option GiottoLens.preferences_file, else
# preferences.json in GiottoLens's user config folder
.lens_pref_file <- function() getOption("GiottoLens.preferences_file",
    file.path(tools::R_user_dir("GiottoLens", "config"), "preferences.json"))

# The preferences that were set, by name; unknown or invalid entries of the
# file are left out
.lens_pref_read <- function() {
    f <- .lens_pref_file()
    if (!file.exists(f)) return(list())
    x <- tryCatch(jsonlite::read_json(f, simplifyVector = FALSE), error = function(e) NULL)
    set <- x$set
    if (!is.list(set)) return(list())
    spec <- .lens_pref_spec()
    out <- list()
    for (k in intersect(names(set), names(spec))) {
        v <- tryCatch(.lens_pref_check(k, set[[k]], spec[[k]]), error = function(e) NULL)
        if (!is.null(v)) out[[k]] <- v
    }
    out
}

.lens_pref_write <- function(set) {
    f <- .lens_pref_file()
    dir.create(dirname(f), recursive = TRUE, showWarnings = FALSE)
    tmp <- paste0(f, ".tmp")
    obj <- list(version = 1L, set = if (length(set)) set else structure(list(), names = character()))
    writeLines(jsonlite::toJSON(obj, auto_unbox = TRUE, pretty = TRUE, digits = NA), tmp)
    file.rename(tmp, f)
    invisible(f)
}

# A value for preference `k`, checked against its spec; an error if invalid
.lens_pref_check <- function(k, v, sp = .lens_pref_spec()[[k]]) {
    bad <- function(what) stop("`", k, "` must be ", what, call. = FALSE)
    one <- function(x) (is.character(x) || is.numeric(x)) && length(x) == 1L && !is.na(x)
    hex <- function(x) is.character(x) && length(x) == 1L && grepl("^#[0-9A-Fa-f]{6}$", x)
    switch(sp$type,
        choice = {
            if (!is.character(v) || length(v) != 1L || !v %in% sp$choices)
                bad(paste0("one of ", paste0("\"", sp$choices, "\"", collapse = ", ")))
            v
        },
        number = {
            x <- suppressWarnings(as.numeric(unlist(v)))
            if (length(x) != 1L || !is.finite(x) || x < sp$min || x > sp$max)
                bad(paste0("a number from ", sp$min, " to ", sp$max))
            if (isTRUE(sp$integer)) {
                if (x != round(x)) bad("a whole number")
                as.integer(x)
            } else x
        },
        color = {
            if (!hex(v)) bad("a color as \"#rrggbb\"")
            tolower(v)
        },
        text = {
            if (!one(v)) bad("one string")
            trimws(as.character(v))
        })
}

# The value of preference `k`: the one set, else the built-in default
.lens_pref <- function(k) {
    set <- .lens_pref_read()
    if (!is.null(set[[k]])) set[[k]] else .lens_pref_spec()[[k]]$default
}

# What the viewer gets: the built-in defaults and the preferences set
.lens_pref_msg <- function() {
    spec <- .lens_pref_spec()
    set <- .lens_pref_read()
    list(defaults = lapply(spec, `[[`, "default"),
        set = if (length(set)) set else structure(list(), names = character()))
}

# Sends the preferences to the open viewers
.lens_pref_broadcast <- function() {
    msg <- .encode_ws_message("preferences", .lens_pref_msg())
    for (v in as.list(.lens_registry))
        try(v$.__enclos_env__$private$broadcast(msg), silent = TRUE)
    invisible()
}

#' Preferences for every viewer
#'
#' Reads or sets defaults that every viewer starts from: continuous color
#' scales, category and transcript colors, the background, cell outlines and
#' fill, the expression values the picker opens on and region comparisons
#' read, the column cells are colored by at launch, and settings of an
#' analysis. The Preferences dialog, opened by the gear in the viewer's tools
#' bar, sets the same. Only preferences that are set are saved;
#' the others take the built-in default of the installed GiottoLens, so they
#' follow its defaults when it is updated. Launch arguments, R options and
#' changes made in a viewer take precedence over preferences.
#'
#' Preferences are saved per user in `preferences.json` in
#' `tools::R_user_dir("GiottoLens", "config")`, or in the file named by
#' option `GiottoLens.preferences_file`. Open viewers get the new values at
#' once.
#'
#' Preferences:
#' * `seq_palette`, `div_palette`: palette of sequential and divergent color
#'   scales.
#' * `scale_style`: style of a continuous scale, `"divergent"` or
#'   `"sequential"`.
#' * `gene_style`: style of the color scale genes share (every expression
#'   item, adr/0024); `"default"` takes `scale_style`.
#' * `cat_palette`: colors of categories, `"default"`, `"vivid"` or
#'   `"okabe_ito"`.
#' * `tx_palette`: transcript colors, `"default"` or `"vivid"`.
#' * `background`: color behind the cells, `"#rrggbb"`; unset, the theme's.
#' * `outline_color`, `outline_width`, `outline_opacity`: cell outlines.
#' * `selection_color`: the color selected cells draw in, `"#rrggbb"` (see
#'   [LensViewer] `$set_selection_color()`).
#' * `fill_opacity`: polygon fill opacity of a colored cell.
#' * `expr_values`: the expression values the picker opens on, when the
#'   object has them.
#' * `de_values`: the expression values `compare_regions()` and the Regions
#'   panel read, when the object has them.
#' * `color_by`: comma-separated metadata columns; cells are colored by the
#'   first one present when a viewer starts without saved settings.
#' * `threads`, `history`, `network_dir`: defaults of
#'   [LensViewer] `$analysis()` `threads`, of option
#'   `GiottoLens.analysis_history` and of `network_dir` (empty: the user
#'   cache).
#' * `import_dir`: the folder a project imported from a dataset goes in by
#'   default (empty: the folder of the project open, else the working
#'   directory); see [LensViewer] `$import_dataset()`.
#'
#' @param ... `name = value` pairs to set; `name = NULL` takes the built-in
#'   default again.
#' @param reset `TRUE` to clear every preference, or names of preferences to
#'   clear.
#' @return A list of every preference's value, the set ones named in
#'   attribute `set`; invisibly when preferences were changed.
#' @examples
#' \dontrun{
#' lens_preferences(seq_palette = "magma", cat_palette = "okabe_ito")
#' lens_preferences(reset = "seq_palette")
#' }
#' @export
lens_preferences <- function(..., reset = NULL) {
    args <- list(...)
    spec <- .lens_pref_spec()
    if (length(args) && (is.null(names(args)) || any(!nzchar(names(args)))))
        stop("[lens_preferences] preferences must be given as name = value", call. = FALSE)
    unknown <- setdiff(c(names(args), if (is.character(reset)) reset), names(spec))
    if (length(unknown))
        stop("[lens_preferences] no preference ", paste0("'", unknown, "'", collapse = ", "),
            "; preferences: ", paste(names(spec), collapse = ", "), call. = FALSE)
    if (!is.null(reset) && !isTRUE(reset) && !is.character(reset))
        stop("[lens_preferences] `reset` must be TRUE or preference names", call. = FALSE)
    set <- .lens_pref_read()
    changed <- length(args) > 0L || !is.null(reset)
    if (isTRUE(reset)) set <- list()
    else if (is.character(reset)) set[reset] <- NULL
    for (k in names(args)) {
        v <- args[[k]]
        if (is.null(v)) { set[[k]] <- NULL; next }
        set[[k]] <- tryCatch(.lens_pref_check(k, v, spec[[k]]),
            error = function(e) stop("[lens_preferences] ", conditionMessage(e), call. = FALSE))
    }
    if (changed) {
        .lens_pref_write(set)
        .lens_pref_broadcast()
    }
    out <- lapply(stats::setNames(names(spec), names(spec)), function(k)
        if (!is.null(set[[k]])) set[[k]] else spec[[k]]$default)
    attr(out, "set") <- names(set)
    if (changed) invisible(out) else out
}

# Preferences sent by the viewer's Preferences dialog: `set` holds values to
# set, `reset` names to clear (or TRUE)
.lens_pref_from_viewer <- function(dat) {
    args <- dat$set %||% list()
    reset <- dat$reset
    if (isTRUE(reset)) return(invisible(lens_preferences(reset = TRUE)))
    reset <- if (length(reset)) as.character(unlist(reset))
    args <- lapply(args, function(v) if (is.list(v) && !is.null(names(v))) v else
        if (is.list(v)) unlist(v) else v)
    do.call(lens_preferences, c(args, list(reset = reset)))
}
