# ── Analysis catalog ─────────────────────────────────────────────────────────
#
# The analyses viewer$analysis() offers. Each is a function named
# `.analysis_entry_<id>()` (one file per analysis) returning
#   id, label       : id (letters, digits, "_") and name shown in the viewer
#   order           : position in the Add analysis dialog
#   auto            : TRUE when stale steps run without Run (Preprocessing only)
#   brief           : one sentence
#   description     : a few sentences
#   inputs, outputs : character vectors
#   steps           : named list of steps (see analysis-steps.R); step ids are
#                     unique across the catalog
# A step may also have `kind` ("source" or "groups", see analysis-shared.R),
# `markers = TRUE` (`p$cell_markers` holds the marker list of
# viewer$analysis(cell_markers =)),
# `code(p, up)`, the R code of the step as a string, and `view(res, p)`, run
# in the main session on the step's result, returning `panels` (list of
# list(id, title, spec) for push_panel()), `tables` (from
# `.analysis_table()`) and `color` (a metadata column to color the cells by).
# `pick(value, res, p)`, run in the main session on a click on a point of one
# of the step's panels (a `pick` param, see panels/spec.js), returns
# `feature` (a gene: the cells are colored by it), `pair` (two cell types:
# the cells are colored by the cell type column and only those types drawn),
# `color` (a metadata column: the cells are colored by it) or `set` (parameter
# values of the step by id: they are set and the step run).
#
# Each parameter has a `help` text, shown by the "?" next to it: the text of
# the Giotto argument it is passed to, from the installed help files
# (analysis-rd-help.R), else the text set on the parameter, by `.with_help()`
# in a step builder, or by a function `.analysis_help_<id>()` returning help
# by step and parameter.
#
# A parameter marked by `.advanced()` is shown under the step's Advanced
# settings, collapsed by default.
#
# A parameter with `show_if = list(<param> = <values>)` applies only when the
# named parameter of the same step has one of those values: the viewer hides
# it otherwise and it is left out of the step's key. It is set on the
# parameter, by `.with_show()` in a step builder, or by `.analysis_show_<id>()`.

.analysis_catalog <- function() {
    env <- environment(.analysis_catalog)
    fns <- ls(env, pattern = "^\\.analysis_entry_", all.names = TRUE)
    ents <- lapply(fns, function(f) get(f, envir = env)())
    names(ents) <- vapply(ents, `[[`, "", "id")
    ord <- vapply(ents, function(e) as.numeric(e$order %||% 100), 1)
    ents <- ents[order(ord, names(ents))]
    for (k in names(ents)) {
        for (s in names(ents[[k]]$steps)) ents[[k]]$steps[[s]]$pipeline <- k
        hf <- get0(paste0(".analysis_help_", k), envir = env, mode = "function")
        h <- if (!is.null(hf)) hf() else list()
        for (s in intersect(names(h), names(ents[[k]]$steps)))
            ents[[k]]$steps[[s]] <- .with_help(ents[[k]]$steps[[s]], h[[s]])
        sf <- get0(paste0(".analysis_show_", k), envir = env, mode = "function")
        w <- if (!is.null(sf)) sf() else list()
        for (s in intersect(names(w), names(ents[[k]]$steps)))
            ents[[k]]$steps[[s]] <- .with_show(ents[[k]]$steps[[s]], w[[s]])
        for (s in names(ents[[k]]$steps))
            ents[[k]]$steps[[s]] <- .with_rd_help(ents[[k]]$steps[[s]])
    }
    ents
}

# A step with `help` set on its parameters, by parameter id
.with_help <- function(step, help) {
    step$params <- lapply(step$params, function(par) {
        if (!is.null(help[[par$id]])) par$help <- help[[par$id]]
        par
    })
    step
}

# Every step of the catalog, by id
.analysis_steps <- function()
    unlist(unname(lapply(.analysis_catalog(), `[[`, "steps")), recursive = FALSE)

# A step with `show_if` set on its parameters, by parameter id
.with_show <- function(step, show) {
    step$params <- lapply(step$params, function(par) {
        if (!is.null(show[[par$id]])) par$show_if <- show[[par$id]]
        par
    })
    step
}

# Whether a parameter applies, given the keys of its step's parameters
.param_shown <- function(par, values) {
    for (ctrl in names(par$show_if))
        if (!isTRUE(values[[ctrl]] %in% as.character(par$show_if[[ctrl]]))) return(FALSE)
    TRUE
}

# A parameter shown under Advanced settings
.advanced <- function(par) {
    par$advanced <- TRUE
    par
}
