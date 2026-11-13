#' Prepare combined cell metadata for the GiottoLens viewer
#'
#' Joins cell-level metadata with dimension reduction coordinates into a single
#' data.frame ready for [launch_lens()] or [LensViewer]`$push_metadata()`.
#' Inspect or modify the result before pushing if needed.
#'
#' `dimreds` accepts names as they appear in `list_dim_reductions(g)$name`
#' (e.g. `"umap.projection"`, `"pca"`) **or** by `dim_type`
#' (e.g. `"umap"`, `"pca"`); the first match is used.
#'
#' @param x          A giotto object.
#' @param cols       Metadata columns to include. `NULL` (default) includes
#'                   all columns. A character vector selects columns as they
#'                   are. A named list or named character vector also sets how
#'                   the viewer treats each column: names are the columns,
#'                   values are `"categorical"` (alias `"factor"`) or
#'                   `"continuous"` (alias `"numeric"`), e.g.
#'                   `list(leiden_clus = "categorical", nr_feats = "continuous")`.
#'                   Unnamed entries are kept without casting.
#' @param dimreds    Character vector of dimension reduction names or types
#'                   (see `list_dim_reductions(g)`).  `NULL` skips all.
#' @param dims       Integer vector of axes to pull from each reduction
#'                   (default `1:2`, silently capped to available axes).
#' @param spat_unit  Spatial unit key (default `"cell"`).
#' @param feat_type  Feature type key for dimension reductions (default `"rna"`).
#'
#' @return A `data.frame` with `cell_ID` plus selected metadata and dim-red
#'   columns named `<name>_<dim>` (e.g. `umap.projection_1`, `umap.projection_2`).
#' @export
prep_meta <- function(
    x,
    cols       = NULL,
    dimreds    = NULL,
    dims       = 1:2,
    spat_unit  = "cell",
    feat_type  = "rna"
) {
    if (!requireNamespace("GiottoClass", quietly = TRUE))
        stop("GiottoClass is required for prep_meta()")

    meta   <- as.data.frame(GiottoClass::pDataDT(x, spat_unit = spat_unit))
    id_col <- if ("cell_ID" %in% names(meta)) "cell_ID" else names(meta)[1L]

    casts <- .parse_col_types(cols)
    if (!is.null(cols)) {
        missing_cols <- setdiff(names(casts), names(meta))
        if (length(missing_cols))
            warning("[prep_meta] column(s) not in cell metadata: ",
                paste(missing_cols, collapse = ", "), call. = FALSE)
        meta <- meta[, unique(c(id_col, intersect(names(casts), names(meta)))), drop = FALSE]
    }
    for (cn in intersect(names(casts)[!is.na(casts)], names(meta))) {
        meta[[cn]] <- switch(casts[[cn]],
            categorical = as.factor(meta[[cn]]),
            continuous  = as.numeric(meta[[cn]])
        )
    }

    if (!is.null(dimreds)) {
        # Build lookup table: name → dim_type
        dr_registry <- as.data.frame(GiottoClass::list_dim_reductions(x))

        for (dr_query in dimreds) {
            # Match by name first, then by dim_type
            dr_row <- NULL
            if (!is.null(dr_registry)) {
                idx <- which(
                    dr_registry$name      == dr_query &
                    dr_registry$spat_unit == spat_unit &
                    dr_registry$feat_type == feat_type
                )
                if (!length(idx))
                    idx <- which(
                        dr_registry$dim_type  == dr_query &
                        dr_registry$spat_unit == spat_unit &
                        dr_registry$feat_type == feat_type
                    )
                if (length(idx)) dr_row <- dr_registry[idx[1L], ]
            }

            if (is.null(dr_row)) {
                warning("prep_meta: '", dr_query, "' not found in list_dim_reductions()",
                        call. = FALSE)
                next
            }

            dr_mat <- tryCatch(
                GiottoClass::getDimReduction(
                    x,
                    spat_unit        = spat_unit,
                    feat_type        = feat_type,
                    reduction        = dr_row$data_type,
                    reduction_method = dr_row$dim_type,
                    name             = dr_row$name,
                    output           = "matrix"
                ),
                error = function(e) {
                    warning("prep_meta: could not load '", dr_row$name, "': ",
                            conditionMessage(e), call. = FALSE)
                    NULL
                }
            )
            if (is.null(dr_mat)) next

            d <- dims[dims <= ncol(dr_mat)]
            if (!length(d)) next

            dr_sub            <- as.data.frame(dr_mat[, d, drop = FALSE])
            colnames(dr_sub)  <- paste0(dr_row$name, "_", d)
            dr_sub[[id_col]]  <- rownames(dr_mat)

            meta <- merge(meta, dr_sub, by = id_col, all.x = TRUE)
        }
    }

    meta
}

# Write metadata for the viewer and return the load_metadata payload.
# Each column is its own file of values in the viewer's cell order (`cell_ids`,
# from the cells table), so the browser fetches only the columns it uses and
# reads each straight into a typed array indexed by cell: no key column, no
# join. Categorical columns are written as 0-based integer codes (NA = -1)
# with their levels in the payload; continuous columns as doubles.
# Factor, character and logical columns are categorical; integer and double
# columns are continuous unless `types` (column -> "categorical") names them.
# A text or logical column `types` names "continuous" is, when every value
# reads as a number. Numeric columns carry `numeric = TRUE` in the payload;
# text columns whose labels all read as numbers `number_text = TRUE`.
# The files are the only copy: R reads columns back from them
# (.read_meta_column()) and changes a column's type by rewriting its file
# (.retype_meta()). `values` keeps the numbers behind each numeric column
# shown as categories, so it can go back to continuous exactly. A `types`
# entry over the level limit is not applied; its column is in `dropped`.
.write_metadata <- function(meta, dir, cell_ids, types = NULL, site = "push_metadata") {
    if (!"cell_ID" %in% names(meta))
        stop("[", site, "] metadata needs a `cell_ID` column matching the ",
            "cell IDs", call. = FALSE)
    if (is.null(cell_ids))
        stop("[", site, "] the viewer has no cells to attach metadata to",
            call. = FALSE)
    # Sanitising can merge names, so make them unique again
    names(meta) <- make.unique(.meta_name(names(meta)), sep = "_")
    row <- match(cell_ids, as.character(meta$cell_ID))
    unmatched <- nrow(meta) - sum(!is.na(row))
    if (all(is.na(row)))
        stop("[", site, "] no cell_ID matches a cell in the viewer",
            call. = FALSE)
    if (unmatched > 0L)
        message("[", site, "] ", unmatched, " metadata row(s) have no cell ",
            "in the viewer and are not shown")

    data_cols <- setdiff(names(meta), "cell_ID")
    if (!length(data_cols))
        stop("[", site, "] metadata has no columns besides cell_ID", call. = FALSE)
    columns <- list()
    values  <- list()
    dropped <- character()
    for (cn in data_cols) {
        v <- meta[[cn]][row]
        numeric <- is.numeric(v)
        entry <- NULL
        if (numeric && identical(unname(types[cn]), "categorical")) {
            lv <- .numeric_levels(v)
            if (length(lv) <= .max_numeric_levels) {
                enc <- .encode_numeric_categories(v, cn, lv)
                entry <- c(enc$entry, url = .write_meta_column(dir, cn, enc$codes))
                values[[cn]] <- lv
            } else {
                warning("[", site, "] `", cn, "` has ", length(lv), " distinct values, ",
                    "more than the ", .max_numeric_levels, " that can be shown as ",
                    "categories; it is continuous", call. = FALSE)
                dropped <- c(dropped, cn)
            }
        }
        if (!numeric && identical(unname(types[cn]), "continuous")) {
            x <- .parse_numbers(v)
            if (!is.null(x)) {
                entry <- list(name = cn, kind = "continuous", numeric = TRUE,
                    url = .write_meta_column(dir, cn, x))
            } else {
                warning("[", site, "] `", cn, "` has values that are not numbers; ",
                    "it is categorical", call. = FALSE)
                dropped <- c(dropped, cn)
            }
        }
        if (is.null(entry)) entry <- if (is.factor(v) || is.character(v) || is.logical(v)) {
            f <- if (is.factor(v)) droplevels(v) else factor(v)
            e <- list(name = cn, kind = "categorical", levels = as.list(levels(f)),
                url = .write_meta_column(dir, cn, .category_codes(f)))
            # Text that reads as numbers can be shown as a continuous scale.
            # Not numeric_*: `entry$numeric` would partial-match it
            if (!is.logical(v) && nlevels(f) && !is.null(.parse_numbers(levels(f))))
                e$number_text <- TRUE
            e
        } else {
            list(name = cn, kind = "continuous", numeric = TRUE,
                url = .write_meta_column(dir, cn, as.double(v)))
        }
        columns[[length(columns) + 1L]] <- entry
    }
    list(msg = list(n = length(cell_ids), columns = columns), values = values,
        dropped = dropped)
}

# Rewrite one numeric column (`entry`, from the payload) as `type`; only its
# file changes. `values`: the numbers behind the column's categories, when it
# is categorical now. Returns the new entry and its `values` (NULL when
# continuous). A text column whose labels are numbers (`number_text`) goes
# to continuous and is numeric from then on: back to categorical, its labels
# are the numbers' (.numeric_labels()), not the text it had.
.retype_meta <- function(dir, entry, type, values = NULL) {
    cn <- entry$name
    v  <- arrow::read_parquet(.meta_column_path(dir, entry), mmap = FALSE)$value
    if (!isTRUE(entry$numeric)) {
        lv <- .parse_numbers(unlist(entry$levels))
        if (type != "continuous" || is.null(lv))
            stop("[LensViewer] `", cn, "` has values that are not numbers", call. = FALSE)
        return(list(entry = list(name = cn, kind = "continuous", numeric = TRUE,
            url = .write_meta_column(dir, cn, lv[ifelse(v < 0L, NA, v + 1L)])), values = NULL))
    }
    if (type == "categorical") {
        lv <- .numeric_levels(v)
        if (length(lv) > .max_numeric_levels)
            stop("[LensViewer] `", cn, "` has ", length(lv), " distinct values; ",
                "at most ", .max_numeric_levels, " can be shown as categories", call. = FALSE)
        enc <- .encode_numeric_categories(v, cn, lv)
        list(entry = c(enc$entry, url = .write_meta_column(dir, cn, enc$codes)), values = lv)
    } else {
        x <- as.double(values[ifelse(v < 0L, NA, v + 1L)])
        list(entry = list(name = cn, kind = "continuous", numeric = TRUE,
            url = .write_meta_column(dir, cn, x)), values = NULL)
    }
}

# One column as R sees it: continuous as doubles, categorical as a factor of
# its labels
.read_meta_column <- function(dir, entry) {
    v <- arrow::read_parquet(.meta_column_path(dir, entry), mmap = FALSE)$value
    if (entry$kind != "categorical") return(as.double(v))
    lv <- as.character(unlist(entry$levels))
    factor(lv[ifelse(v < 0L, NA, v + 1L)], levels = lv)
}

.meta_column_path <- function(dir, entry) file.path(dir, basename(entry$url))

# A column's file is named by its content, so the same values keep the same
# URL across pushes (the browser keeps a column it has) and changed values
# never reuse a cached one. Returns the URL, relative to the page.
.write_meta_column <- function(dir, name, x) {
    tmp <- tempfile("col", tmpdir = dir, fileext = ".tmp")
    arrow::write_parquet(data.frame(value = x), tmp)
    path <- file.path(dir, sprintf("%s-%s.parquet", name, unname(tools::md5sum(tmp))))
    if (file.exists(path)) unlink(tmp) else file.rename(tmp, path)
    paste0("session/metadata/", basename(path))
}

# Files no payload in `keep` points to. The viewer keeps the previous
# payload's files too, so a tab still fetching one when new metadata arrives
# does not lose it.
.prune_meta_files <- function(dir, keep) {
    files <- list.files(dir, pattern = "\\.parquet$")
    unlink(file.path(dir, setdiff(files, basename(keep))))
}

# Column names as the viewer keeps them: dots and other characters break
# identifiers downstream
.meta_name <- function(x) gsub("[^A-Za-z0-9_]", "_", x)

# `v` as doubles when every value that is not NA reads as a number, else NULL
.parse_numbers <- function(v) {
    if (is.logical(v)) return(as.double(v))
    s <- as.character(v)
    x <- suppressWarnings(as.numeric(s))
    if (any(is.na(x) & !is.na(s))) NULL else x
}

# Payload `new`'s columns added to `old`'s, a column of the same name
# replaced where it was
.merge_meta <- function(old, new) {
    cols <- old$columns %||% list()
    for (cl in new$columns) {
        i <- match(cl$name, vapply(cols, `[[`, "", "name"))
        if (is.na(i)) cols[[length(cols) + 1L]] <- cl else cols[[i]] <- cl
    }
    list(n = new$n, columns = cols)
}

.category_codes <- function(f) {
    codes <- as.integer(f) - 1L
    codes[is.na(codes)] <- -1L
    codes
}

# Numeric columns shown as categories: one per distinct value, in numeric
# order, labelled without scientific notation. Rules and the legend match on
# these labels, so keep the format stable.
.max_numeric_levels <- 1000L
.numeric_levels <- function(v) sort(unique(v[!is.na(v)]))
.numeric_labels <- function(lv) vapply(lv, function(z) format(z, scientific = FALSE,
    digits = 15, drop0trailing = TRUE, trim = TRUE), "")
.encode_numeric_categories <- function(v, name, lv) {
    codes <- match(v, lv) - 1L
    codes[is.na(codes)] <- -1L
    list(codes = codes, entry = list(name = name, kind = "categorical",
        levels = as.list(.numeric_labels(lv)), numeric = TRUE))
}

# `cols` -> named character vector of column -> viewer type (NA = no cast)
.parse_col_types <- function(cols) {
    if (is.null(cols)) return(NULL)
    if (is.null(names(cols))) {
        cols <- as.character(unlist(cols))
        return(stats::setNames(rep(NA_character_, length(cols)), cols))
    }
    nms   <- names(cols)
    vals  <- vapply(cols, function(v) as.character(v)[1L], character(1L))
    plain <- !nzchar(nms)
    nms[plain]  <- vals[plain]
    vals[plain] <- NA_character_
    aliases <- c(categorical = "categorical", factor = "categorical",
                 continuous = "continuous", numeric = "continuous")
    bad <- !is.na(vals) & !vals %in% names(aliases)
    if (any(bad)) {
        stop("[prep_meta] unknown column type(s): ",
            paste0(nms[bad], " = \"", vals[bad], "\"", collapse = ", "),
            "; use \"categorical\" or \"continuous\"", call. = FALSE)
    }
    stats::setNames(unname(aliases[vals]), nms)
}
