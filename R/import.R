# ── Importing a dataset into a new GiottoDisk project (adr/0027) ─────────────
#
# The page asks R to detect a platform's output folder (`import_detect`): R
# creates Giotto's reader for it, without a backend, and answers a form, one
# field per argument of the platform's createGiotto*Object(), filled from the
# reader's paths and its create_gobject() defaults. The page sends the edited
# values back (`import_run`); R passes the reader only the arguments whose
# value differs from the reader's default, and runs the import as a job in a
# daemon of its own (.jw_import()).

# Platforms: the reader's create function in Giotto, its folder argument, the
# form and the arguments from the form's values
.import_platforms <- function() list(
    xenium = list(label = "Xenium", fun = "createGiottoXeniumObject", dir_arg = "xenium_dir",
        form = .import_xenium_form, args = .import_xenium_args)
)

.import_spec <- function(platform, site) {
    p <- .import_platforms()
    if (!is.character(platform) || length(platform) != 1L || !platform %in% names(p))
        stop("[", site, "] `platform` must be one of ", paste0("\"", names(p), "\"", collapse = ", "),
            call. = FALSE)
    if (!requireNamespace("Giotto", quietly = TRUE) ||
            !requireNamespace("GiottoDisk", quietly = TRUE))
        stop("[", site, "] importing needs Giotto and GiottoDisk", call. = FALSE)
    c(list(platform = platform), p[[platform]])
}

# The dataset folder, absolute
.import_dir_check <- function(dir, site) {
    if (!is.character(dir) || length(dir) != 1L || is.na(dir) || !nzchar(dir))
        stop("[", site, "] `dir` must be a folder path", call. = FALSE)
    dir <- path.expand(dir)
    if (!dir.exists(dir)) stop("[", site, "] no folder ", dir, call. = FALSE)
    normalizePath(dir)
}

# A path as the page lists it: whether it exists, is a folder, its size in bytes
.import_path_info <- function(path) {
    path <- as.character(path %||% "")
    if (!length(path) || !nzchar(path[[1L]]))
        return(list(path = "", exists = FALSE, dir = FALSE, size = NULL))
    path <- path[[1L]]
    dir <- dir.exists(path)
    size <- if (dir) {
        f <- list.files(path, recursive = TRUE, full.names = TRUE)
        sum(file.size(f), na.rm = TRUE)
    } else if (file.exists(path)) file.size(path)
    list(path = path, exists = file.exists(path), dir = dir, size = size)
}

# ── Form ─────────────────────────────────────────────────────────────────────

# The form for `dir`: list(platform, dir, label, info, notes, fields,
# project, snapshot, code). `base`: the folder the default project goes in.
.import_detect <- function(platform, dir, base, site) {
    spec <- .import_spec(platform, site)
    dir <- .import_dir_check(dir, site)
    notes <- character()
    op <- options(giotto.no_python_warn = TRUE)
    on.exit(options(op), add = TRUE)
    form <- tryCatch(withCallingHandlers(spec$form(dir),
        warning = function(w) {
            notes <<- c(notes, trimws(conditionMessage(w)))
            invokeRestart("muffleWarning")
        },
        message = function(m) {
            notes <<- c(notes, trimws(gsub("\\s+", " ", conditionMessage(m))))
            invokeRestart("muffleMessage")
        }), error = function(e)
            stop("[", site, "] Giotto could not read ", dir, ": ", conditionMessage(e), call. = FALSE))
    project <- .import_default_project(dir, base)
    out <- c(list(platform = spec$platform, label = spec$label, dir = dir), form,
        list(notes = as.list(unique(notes)), project = project, snapshot = "imported"))
    # What stops an import with the values as detected
    args <- tryCatch(spec$args(out, list()), error = function(e) e)
    if (inherits(args, "error")) {
        out$problem <- conditionMessage(args)
        args <- list()
    }
    out$code <- .import_code(spec, dir, args, project, "imported", NULL)
    out
}

# The reader's argument values from the page's `values` (by field key; a
# field left out keeps the form's value). Only arguments that differ from the
# reader's default.
.import_form_args <- function(form, values, site) {
    spec <- .import_spec(form$platform, site)
    if (!is.null(values) && !is.list(values))
        stop("[", site, "] `values` must be a list by field", call. = FALSE)
    spec$args(form, values %||% list())
}

# A field: `value` is what the form shows first, `default` the reader's own
.import_field <- function(key, label, group, type, value, default = value, help = NULL, ...) {
    c(list(key = key, label = label, group = group, type = type, value = value,
        default = default, help = help), list(...))
}

.import_rows_paths <- function(rows, keys = "path") {
    lapply(rows, function(r) {
        for (k in keys) r[[paste0(k, "_info")]] <- .import_path_info(r[[k]])
        r
    })
}

# ── Xenium ───────────────────────────────────────────────────────────────────

.import_xenium_form <- function(dir) {
    x <- Giotto::importXenium(dir)
    p <- x@paths
    fun <- x$create_gobject
    f <- formals(fun)
    def <- function(k) eval(f[[k]], environment(fun))
    first <- function(v) if (length(v)) as.character(v[[1L]]) else ""

    path_field <- function(key, label, value, help) {
        value <- first(value)
        .import_field(key, label, "files", "path", value, help = help,
            info = .import_path_info(value))
    }

    # Boundaries: the reader's names, each with the file it resolves to
    bnd <- def("load_bounds")
    resolved <- list(cell = first(p$cell_bound_path), nucleus = first(p$nuc_bound_path))
    bounds <- lapply(names(bnd), function(n) {
        path <- if (identical(bnd[[n]], n) && n %in% names(resolved)) resolved[[n]] else first(bnd[[n]])
        list(name = n, path = path, on = nzchar(path))
    })

    # Focus images: the files the reader loads for "focus"
    focus <- .import_xenium_focus(first(p$img_focus_path))
    images <- lapply(seq_along(focus), function(i)
        list(name = names(focus)[[i]], path = focus[[i]], on = TRUE))
    mip <- first(p$img_mip_path)
    if (nzchar(mip) && file.exists(mip))
        images <- c(images, list(list(name = "mip", path = mip, on = FALSE)))
    images_default <- if (identical(def("load_images"), "focus")) images[vapply(images, `[[`, NA, "on")]
        else list()

    aligned <- .import_find_aligned(dir)

    ft <- def("feat_type")
    sk <- def("split_keyword")
    feat <- c(list(list(feat_type = ft[[1L]], keywords = "")), lapply(seq_along(sk), function(i)
        list(feat_type = ft[[i + 1L]], keywords = paste(sk[[i]], collapse = ", "))))

    fields <- list(
        path_field("transcript_path", "Transcripts", p$tx_path,
            "Subcellular transcript detections (parquet, csv or zarr)"),
        .import_field("bounds_path", "Boundaries", "files", "rows",
            .import_rows_paths(bounds), columns = list("name", "path"),
            help = "Polygon sets, each loaded as a spatial unit of its name"),
        path_field("expression_path", "Expression matrix", def("expression_path"),
            "Cell feature matrix (h5, mtx folder or zarr)"),
        path_field("cell_metadata_path", "Cell metadata", def("metadata_path"),
            "Cell metadata (parquet, csv or zarr); loaded when Load cell metadata is on"),
        path_field("gene_panel_json_path", "Gene panel", def("gene_panel_json_path"),
            "Panel JSON with feature metadata; optional"),
        .import_field("load_images", "Images", "images", "rows", .import_rows_paths(images),
            default = images_default, columns = list("name", "path"),
            help = "Morphology images, each loaded under its name"),
        .import_field("load_aligned_images", "Aligned images", "images", "rows",
            .import_rows_paths(aligned, c("path", "alignment")), default = list(),
            columns = list("name", "path", "alignment"),
            help = "Images with an alignment matrix CSV, such as a post-Xenium H&E"),
        .import_field("load_transcripts", "Load transcripts", "loading", "bool",
            isTRUE(def("load_transcripts"))),
        .import_field("load_expression", "Load expression matrix", "loading", "bool",
            isTRUE(def("load_expression"))),
        .import_field("load_cellmeta", "Load cell metadata", "loading", "bool",
            isTRUE(def("load_cellmeta"))),
        .import_field("qv_threshold", "QV threshold", "loading", "number", as.numeric(x@qv),
            help = "Minimum Phred-scaled quality score of a transcript", min = 0),
        .import_field("feat_type", "Feature types", "loading", "rows", feat,
            columns = list("feat_type", "keywords"),
            help = paste("Transcripts whose name matches a row's keywords get its feature type;",
                "the first row takes the others"))
    )
    list(info = .import_xenium_info(first(p$experiment_info_path), x@micron), fields = fields)
}

# Focus image files by name, as the reader loads them for "focus": the
# OME-TIFFs of the focus folder named by their channel, DAPI first; a single
# focus file as "dapi"
.import_xenium_focus <- function(path) {
    if (!nzchar(path) || !file.exists(path)) return(list())
    if (!dir.exists(path)) return(list(dapi = path))
    files <- list.files(path, pattern = "\\.ome\\.tif$", full.names = TRUE)
    if (!length(files)) files <- list.files(path, pattern = "\\.tif$", full.names = TRUE)
    files <- files[!dir.exists(files)]
    if (!length(files)) return(list())
    nm <- sub("^ch\\d+_", "", sub("(\\.ome)?\\.tiff?$", "", basename(files), ignore.case = TRUE))
    dapi <- grepl("dapi", nm, ignore.case = TRUE)
    nm[dapi] <- "dapi"
    ord <- c(which(dapi), which(!dapi))
    stats::setNames(as.list(files[ord]), make.unique(nm[ord], sep = "_"))
}

# Images with an alignment CSV in `dir` or its parent: `<prefix>_imagealignment.csv`
# beside `<prefix>_image.ome.tif` or `<prefix>.ome.tif` (or .tif), named "he"
# for a `<prefix>` ending in `_he`
.import_find_aligned <- function(dir) {
    out <- list()
    for (d in unique(c(dir, dirname(dir)))) {
        csv <- list.files(d, pattern = "_imagealignment\\.csv$", full.names = TRUE)
        for (a in csv) {
            prefix <- sub("_imagealignment\\.csv$", "", a)
            img <- paste0(prefix, rep(c("_image", ""), each = 4L),
                c(".ome.tif", ".ome.tiff", ".tif", ".tiff"))
            img <- img[file.exists(img)]
            if (!length(img)) next
            name <- if (grepl("_he$", prefix)) "he" else basename(prefix)
            out[[length(out) + 1L]] <- list(name = name, path = img[[1L]], alignment = a, on = TRUE)
        }
    }
    nm <- make.unique(vapply(out, `[[`, "", "name"), sep = "_")
    for (i in seq_along(out)) out[[i]]$name <- nm[[i]]
    out
}

# What experiment.xenium says about the run, for the page to show
.import_xenium_info <- function(file, micron) {
    out <- list()
    add <- function(label, value)
        if (length(value) == 1L && !is.na(value) && nzchar(as.character(value)))
            out[[length(out) + 1L]] <<- list(label = label, value = as.character(value))
    if (nzchar(file) && file.exists(file)) {
        e <- tryCatch(jsonlite::fromJSON(file), error = function(e) list())
        add("Run", e$run_name)
        add("Region", e$region_name)
        add("Panel", e$panel_name)
        add("Cells", if (is.numeric(e$num_cells)) format(e$num_cells, big.mark = ","))
        add("Software", e$analysis_sw_version)
    }
    add("Pixel size", if (length(micron)) paste(micron, "\u00b5m"))
    out
}

# The reader's arguments from `form` and the page's `values`
.import_xenium_args <- function(form, values) {
    fields <- stats::setNames(form$fields, vapply(form$fields, `[[`, "", "key"))
    unknown <- setdiff(names(values), names(fields))
    if (length(unknown))
        stop("unknown field: ", paste(unknown, collapse = ", "), call. = FALSE)
    val <- function(k) if (k %in% names(values)) values[[k]] else fields[[k]]$value
    out <- list()

    flag <- function(k) {
        v <- val(k)
        if (!isTRUE(v) && !isFALSE(v)) stop("`", k, "` must be true or false", call. = FALSE)
        v
    }
    loads <- c(transcript_path = "load_transcripts", expression_path = "load_expression",
        cell_metadata_path = "load_cellmeta")
    for (k in loads) {
        v <- flag(k)
        if (!identical(v, fields[[k]]$default)) out[[k]] <- v
    }

    for (k in c("transcript_path", "expression_path", "cell_metadata_path", "gene_panel_json_path")) {
        v <- .import_str(val(k), k)
        used <- if (k %in% names(loads)) flag(loads[[k]]) else nzchar(v)
        if (used && !nzchar(v) && k != "gene_panel_json_path")
            stop("`", k, "`: no file; give one or turn off `", loads[[k]], "`", call. = FALSE)
        if (used && nzchar(v) && !file.exists(v))
            stop("`", k, "`: no file ", v, call. = FALSE)
        if (!identical(v, fields[[k]]$default) && (used || k == "gene_panel_json_path"))
            out[[k]] <- v
    }

    q <- val("qv_threshold")
    if (!is.numeric(q) || length(q) != 1L || is.na(q) || q < 0)
        stop("`qv_threshold` must be a number of at least 0", call. = FALSE)
    if (!isTRUE(all.equal(q, fields$qv_threshold$default))) out$qv_threshold <- q

    # Boundaries: the reader's name keywords where the path is the one it finds
    b <- .import_rows(val("bounds_path"), c("name", "path"), "bounds_path")
    b <- b[vapply(b, function(r) isTRUE(r$on), NA)]
    if (!identical(.import_canon(b), .import_canon(Filter(function(r) isTRUE(r$on),
            fields$bounds_path$default)))) {
        detected <- stats::setNames(lapply(fields$bounds_path$default, `[[`, "path"),
            vapply(fields$bounds_path$default, `[[`, "", "name"))
        out["bounds_path"] <- list(if (length(b)) .import_named(b, function(r) {
            if (!file.exists(r$path)) stop("`bounds_path`: no file ", r$path, call. = FALSE)
            if (identical(detected[[r$name]], r$path) && r$name %in% c("cell", "nucleus")) r$name
            else r$path
        }, "bounds_path"))
    }

    im <- .import_rows(val("load_images"), c("name", "path"), "load_images")
    im <- im[vapply(im, function(r) isTRUE(r$on), NA)]
    if (!length(im)) out["load_images"] <- list(NULL)
    else if (!identical(.import_canon(im), .import_canon(fields$load_images$default)))
        out$load_images <- .import_named(im, function(r) {
            if (!file.exists(r$path)) stop("`load_images`: no file ", r$path, call. = FALSE)
            r$path
        }, "load_images")

    al <- .import_rows(val("load_aligned_images"), c("name", "path", "alignment"),
        "load_aligned_images")
    al <- al[vapply(al, function(r) isTRUE(r$on), NA)]
    if (length(al))
        out$load_aligned_images <- .import_named(al, function(r) {
            for (p in c(r$path, r$alignment)) if (!file.exists(p))
                stop("`load_aligned_images`: no file ", p, call. = FALSE)
            c(r$path, r$alignment)
        }, "load_aligned_images")

    ft <- .import_rows(val("feat_type"), c("feat_type", "keywords"), "feat_type")
    if (!length(ft)) stop("`feat_type`: at least one row", call. = FALSE)
    kw <- lapply(ft, function(r) trimws(strsplit(r$keywords, ",", fixed = TRUE)[[1L]]))
    kw <- lapply(kw, function(k) k[nzchar(k)])
    types <- vapply(ft, `[[`, "", "feat_type")
    if (any(!nzchar(types)) || anyDuplicated(types))
        stop("`feat_type`: each row needs a name of its own", call. = FALSE)
    if (length(kw[[1L]])) stop("`feat_type`: the first row takes no keywords", call. = FALSE)
    if (length(ft) > 1L && any(lengths(kw[-1L]) == 0L))
        stop("`feat_type`: each row after the first needs keywords", call. = FALSE)
    pick <- function(rows) lapply(rows, function(r) r[c("feat_type", "keywords")])
    if (!identical(pick(ft), pick(fields$feat_type$default))) {
        out$feat_type <- types
        out$split_keyword <- kw[-1L]
    }
    out
}

# Rows from the page: a list of lists with character `cols`, and `on`
.import_rows <- function(rows, cols, key) {
    if (is.null(rows)) return(list())
    if (!is.list(rows)) stop("`", key, "` must be a list of rows", call. = FALSE)
    lapply(rows, function(r) {
        if (!is.list(r)) stop("`", key, "` must be a list of rows", call. = FALSE)
        out <- lapply(stats::setNames(cols, cols), function(k) .import_str(r[[k]], key))
        out$on <- if (is.null(r$on)) TRUE else isTRUE(r$on)
        out
    })
}

# Rows by name, through `value`; names must be given and differ
.import_named <- function(rows, value, key) {
    nm <- vapply(rows, `[[`, "", "name")
    if (any(!nzchar(nm)) || anyDuplicated(nm))
        stop("`", key, "`: each row needs a name of its own", call. = FALSE)
    stats::setNames(lapply(rows, value), nm)
}

# Rows without what the page adds (path info), to compare
.import_canon <- function(rows) lapply(rows, function(r)
    r[intersect(c("name", "path", "alignment", "feat_type", "keywords", "on"), names(r))])

.import_str <- function(v, key) {
    if (is.null(v)) return("")
    if (!is.character(v) || length(v) != 1L || is.na(v))
        stop("`", key, "` must be text", call. = FALSE)
    trimws(v)
}

# ── Project ──────────────────────────────────────────────────────────────────

# Paths of cloud-synced folders a project must not go in
.cloud_synced <- function(path) {
    grepl(paste0("(/Library/CloudStorage/|/Library/Mobile Documents/|[/\\\\]OneDrive",
        "|[/\\\\]Dropbox[/\\\\]|[/\\\\]Google Drive[/\\\\]|[/\\\\]iCloud Drive[/\\\\])"),
        paste0(path, "/"), ignore.case = TRUE)
}

# The folder imported projects go in: preference `import_dir`, else
# `fallback`, else R's working directory
.import_base <- function(fallback = NULL) {
    pref <- .lens_pref("import_dir")
    if (nzchar(pref)) return(path.expand(pref))
    fallback %||% getwd()
}

# `<base>/<dataset name>`, with `_2`, `_3`... when taken. The dataset name is
# the folder's, or its parent's for a folder named `outs`.
.import_default_project <- function(dir, base) {
    name <- basename(dir)
    if (tolower(name) == "outs") name <- basename(dirname(dir))
    name <- gsub("^[._]+|_+$", "", gsub("[^A-Za-z0-9._-]+", "_", name))
    if (!nzchar(name)) name <- "giotto_project"
    path <- file.path(base, name)
    i <- 1L
    while (file.exists(path) && length(list.files(path, all.files = TRUE, no.. = TRUE))) {
        i <- i + 1L
        path <- file.path(base, paste0(name, "_", i))
    }
    path
}

# The project folder to create: absolute; not there yet or empty; its parent
# there and writable; not cloud-synced
.import_project_check <- function(path, site) {
    if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(trimws(path)))
        stop("[", site, "] `project` must be a folder path", call. = FALSE)
    path <- normalizePath(path.expand(trimws(path)), mustWork = FALSE)
    if (file.exists(path)) {
        if (!dir.exists(path)) stop("[", site, "] ", path, " is a file", call. = FALSE)
        if (length(list.files(path, all.files = TRUE, no.. = TRUE)))
            stop("[", site, "] ", path, " is not empty; give a new folder", call. = FALSE)
    }
    parent <- dirname(path)
    if (!dir.exists(parent)) stop("[", site, "] no folder ", parent, call. = FALSE)
    if (file.access(parent, 2L) != 0L)
        stop("[", site, "] cannot write in ", parent, call. = FALSE)
    if (.cloud_synced(path))
        stop("[", site, "] ", path, " is in a cloud-synced folder; give a local one",
            call. = FALSE)
    path
}

.import_snapshot_check <- function(name, site) {
    if (!is.character(name) || length(name) != 1L || is.na(name) ||
            !grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", name))
        stop("[", site, "] `snapshot` must be a name of letters, digits, '.', '_' or '-'",
            call. = FALSE)
    name
}

# Arguments given to import_dataset(): names of the reader's arguments
.import_args_check <- function(spec, args, site) {
    if (!length(args)) return(list())
    ok <- setdiff(names(formals(getExportedValue("Giotto", spec$fun))),
        c(spec$dir_arg, "backend", "verbose"))
    nm <- names(args)
    if (is.null(nm) || any(!nzchar(nm)))
        stop("[", site, "] the reader's arguments must be named", call. = FALSE)
    bad <- setdiff(nm, ok)
    if (length(bad))
        stop("[", site, "] not an argument of Giotto::", spec$fun, "(): ",
            paste(bad, collapse = ", "), call. = FALSE)
    args
}

# The R code of an import
.import_code <- function(spec, dir, args, project, snapshot, description) {
    r <- function(v) paste(deparse(v, width.cutoff = 500L), collapse = "")
    a <- c(sprintf("%s = %s", spec$dir_arg, r(dir)),
        if (length(args)) sprintf("%s = %s", names(args), vapply(args, r, "")),
        "backend = src")
    paste(c(
        sprintf("GiottoDisk::setArtifactDumpDir(%s)", r(project)),
        sprintf("src <- GiottoDisk::sourceCreate(%s)", r(project)),
        sprintf("g <- Giotto::%s(\n    %s\n)", spec$fun, paste(a, collapse = ",\n    ")),
        sprintf("GiottoDisk::snapshotSave(src, g, name = %s%s)", r(snapshot),
            if (!is.null(description)) paste0(", description = ", r(description)) else "")
    ), collapse = "\n")
}

# After a failed or cancelled import: the project folder it made, or what it
# wrote in the empty folder it was given
.import_cleanup <- function(path, created) {
    if (!dir.exists(path)) return(invisible())
    if (created) unlink(path, recursive = TRUE)
    else unlink(list.files(path, all.files = TRUE, no.. = TRUE, full.names = TRUE),
        recursive = TRUE)
    invisible()
}

# ── Daemon side (a job in a daemon of its own, jobs.R) ───────────────────────

# Import into a new project at `project`: the reader's messages are the job's
# progress text
.jw_import <- function(fun, args, project, snapshot, description, threads, method) {
    options(giotto.cores = threads, giotto.no_python_warn = TRUE)
    n <- 0L
    note <- function(text) {
        n <<- n + 1L
        .lens_progress(n, 0, trimws(gsub("\\s+", " ", text)))
    }
    note("creating the project")
    GiottoDisk::setArtifactDumpDir(project, verbose = FALSE)
    src <- GiottoDisk::sourceCreate(project)
    reader <- getExportedValue("Giotto", fun)
    g <- withCallingHandlers(do.call(reader, c(args, list(backend = src, verbose = TRUE))),
        message = function(m) {
            note(conditionMessage(m))
            invokeRestart("muffleMessage")
        })
    note("saving the snapshot")
    suppressMessages(GiottoDisk::snapshotSave(src, g, name = snapshot, keep = TRUE,
        creator = "GiottoLens", description = description, method = method, verbose = FALSE))
    list(path = normalizePath(project), name = snapshot)
}
