# ── Help text from the installed help files ─────────────────────────────────
#
# A parameter whose value a step passes straight to an argument of a function
# (`fun(arg = p$param)`, also through a local variable, an argument list for
# do.call() or `...`) takes that argument's text from the function's help
# file, read from the installed package. The text of `.analysis_help_<id>()`
# is kept for the others. When the parameter's default differs from the
# argument's default, the help names the GiottoLens default. A parameter with
# `own_help = TRUE` keeps its own text.

.lens_rd <- new.env(parent = emptyenv())

.rd_packages <- c("Giotto", "GiottoClass", "stats")

# Functions whose `...` reach another documented function
.rd_dots <- character()

.rd_index <- function() {
    if (!is.null(.lens_rd$alias)) return(.lens_rd)
    alias <- list()
    dbs <- list()
    for (p in .rd_packages) {
        db <- tryCatch(if (requireNamespace(p, quietly = TRUE)) tools::Rd_db(p),
            error = function(e) NULL)
        if (is.null(db)) next
        dbs[[p]] <- db
        for (f in names(db)) for (x in Filter(function(x)
            identical(attr(x, "Rd_tag"), "\\alias"), db[[f]])) {
            a <- paste(unlist(x), collapse = "")
            alias[[a]] <- c(alias[[a]], list(list(p = p, f = f)))
        }
    }
    .lens_rd$dbs <- dbs
    .lens_rd$alias <- alias
    .lens_rd$args <- list()
    .lens_rd
}

.rd_flat <- function(x) gsub("\\s+", " ", trimws(paste(unlist(x), collapse = "")))

# Argument texts of a documented function, by argument name
.rd_args <- function(fun) {
    ix <- .rd_index()
    if (!is.null(ix$args[[fun]])) return(ix$args[[fun]])
    out <- list()
    for (h in ix$alias[[fun]]) {
        a <- Filter(function(x) identical(attr(x, "Rd_tag"), "\\arguments"), ix$dbs[[h$p]][[h$f]])
        if (length(a)) for (it in Filter(function(x) identical(attr(x, "Rd_tag"), "\\item"), a[[1L]]))
            for (n in trimws(strsplit(.rd_flat(it[[1L]]), ",")[[1L]]))
                if (is.null(out[[n]])) out[[n]] <- .rd_flat(it[[2L]])
    }
    ix$args[[fun]] <- out
    out
}

# (function, argument, parameter) for each parameter a step passes to an argument
.rd_step_args <- function(step) {
    res <- list()
    vars <- list()
    called <- character()
    pars_in <- function(e) {
        if (is.call(e) && identical(e[[1L]], as.name("$")) && identical(e[[2L]], as.name("p")))
            return(as.character(e[[3L]]))
        if (is.call(e) || is.pairlist(e)) unique(unlist(lapply(as.list(e)[-1L], pars_in)))
        else character()
    }
    fname <- function(h) {
        if (is.call(h) && identical(h[[1L]], as.name("::"))) return(as.character(h[[3L]]))
        if (is.name(h)) return(as.character(h))
        NULL
    }
    walk <- function(e) {
        if (!is.call(e)) return(invisible())
        if (identical(e[[1L]], as.name("<-")) || identical(e[[1L]], as.name("="))) {
            lhs <- e[[2L]]
            ps <- pars_in(e[[3L]])
            if (is.name(lhs) && length(ps) == 1L) vars[[as.character(lhs)]] <<- ps
            if (is.call(lhs) && (identical(lhs[[1L]], as.name("$")) ||
                identical(lhs[[1L]], as.name("[["))) && length(ps) == 1L)
                res[[length(res) + 1L]] <<- list(fun = ".list", arg = as.character(lhs[[3L]]),
                    param = ps)
        }
        f <- fname(e[[1L]])
        if (!is.null(f)) called <<- c(called, f)
        if (identical(e[[1L]], as.name("::"))) called <<- c(called, as.character(e[[3L]]))
        nm <- names(e)
        if (!is.null(f) && !is.null(nm)) for (i in seq_along(e)[-1L]) if (nzchar(nm[[i]])) {
            v <- e[[i]]
            ps <- if (is.name(v)) vars[[as.character(v)]] else pars_in(v)
            if (length(ps) == 1L) res[[length(res) + 1L]] <<- list(fun = if (f == "list") ".list"
                else f, arg = nm[[i]], param = ps)
        }
        for (i in seq_along(e)[-1L]) walk(e[[i]])
    }
    for (fn in list(step$run, step$result)) if (is.function(fn)) walk(body(fn))
    called <- setdiff(unique(called), c("list", "c", "if", "<-", "$", "[[", "::", "paste0",
        "stop", "identical", "is.null", "length", "%||%", "do.call", "as.numeric",
        "as.integer", "as.character", "trimws", "strsplit", "unlist", "set.seed", "suppressWarnings",
        "suppressMessages", "intersect", "setdiff", "nzchar", "is.na", "sprintf", "max", "min"))
    out <- list()
    for (x in res) {
        funs <- if (x$fun == ".list") called else x$fun
        for (f in funs) {
            cand <- c(f, if (f %in% names(.rd_dots)) .rd_dots[[f]])
            cand <- c(cand, paste0(cand, ".default"))
            for (g in cand) {
                txt <- .rd_args(g)[[x$arg]]
                if (!is.null(txt) && is.null(out[[x$param]])) {
                    out[[x$param]] <- list(fun = g, arg = x$arg, text = txt)
                }
            }
        }
    }
    out
}

# The default of a function argument as a key, or NULL when not a single value
.rd_default <- function(fun, arg) {
    f <- NULL
    for (p in .rd_packages) {
        f <- tryCatch(getExportedValue(p, fun), error = function(e) NULL)
        if (is.function(f)) break
    }
    if (!is.function(f)) return(NULL)
    fm <- formals(f)
    if (!arg %in% names(fm)) return(NULL)
    if (is.symbol(fm[[arg]]) && !nzchar(as.character(fm[[arg]]))) return(NULL)
    d <- fm[[arg]]
    if (is.call(d) && identical(d[[1L]], as.name("c"))) d <- d[[2L]]
    if (is.null(d) || !is.atomic(d) || length(d) != 1L) return(NULL)
    as.character(d)
}

# A step with help text from the help files where its parameters pass an argument
.with_rd_help <- function(step, disk = FALSE) {
    m <- tryCatch(.rd_step_args(step), error = function(e) list())
    if (!length(m)) return(step)
    step$params <- lapply(step$params, function(par) {
        x <- m[[par$id]]
        if (is.null(x) || isTRUE(par$own_help)) return(par)
        txt <- x$text
        def <- .default_values(list(s = list(params = list(par))), disk)$s[[par$id]]
        rd_def <- .rd_default(x$fun, x$arg)
        if (!is.null(rd_def) && !is.null(def) && nzchar(def) && !identical(def, "auto") &&
            !identical(def, rd_def)) {
            lab <- def
            if (identical(par$type, "choice")) {
                ch <- Find(function(c) identical(c$value, def), par$choices)
                if (!is.null(ch)) lab <- ch$label
            }
            txt <- paste0(txt, if (!grepl("[.!?]$", txt)) ".", " GiottoLens default: ", lab, ".")
        }
        par$help <- txt
        par$help_src <- paste0(x$fun, "(", x$arg, ")")
        par
    })
    step
}
