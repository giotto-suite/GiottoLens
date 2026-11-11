# ── Analysis catalog ─────────────────────────────────────────────────────────
#
# The analyses launch_lens_analysis() offers. Each is a function named
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
# launch_lens_analysis(cell_markers =)),
# `code(p, up)`, the R code of the step as a string, and `view(res, p)`, run
# in the main session on the step's result, returning `panels` (list of
# list(id, title, spec) for push_panel()) and `tables` (from
# `.analysis_table()`).

.analysis_catalog <- function() {
    env <- environment(.analysis_catalog)
    fns <- ls(env, pattern = "^\\.analysis_entry_", all.names = TRUE)
    ents <- lapply(fns, function(f) get(f, envir = env)())
    names(ents) <- vapply(ents, `[[`, "", "id")
    ord <- vapply(ents, function(e) as.numeric(e$order %||% 100), 1)
    ents <- ents[order(ord, names(ents))]
    for (k in names(ents)) for (s in names(ents[[k]]$steps))
        ents[[k]]$steps[[s]]$pipeline <- k
    ents
}

# Every step of the catalog, by id
.analysis_steps <- function()
    unlist(unname(lapply(.analysis_catalog(), `[[`, "steps")), recursive = FALSE)
