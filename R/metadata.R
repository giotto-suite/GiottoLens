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
# Rows are written in the viewer's cell order (`cell_ids`, from the cells
# table), so the browser reads each column straight into a typed array indexed
# by cell. Categorical columns are written as 0-based integer codes (NA = -1)
# with their levels in the payload; continuous columns as doubles.
# Factor, character and logical columns are categorical; integer and double
# columns are continuous unless `types` (column -> "categorical") names them.
# Numeric columns carry `numeric = TRUE` in the payload.
# The written file is the only copy: R reads columns back from it
# (.read_meta_column()) and changes a column's type in it (.retype_meta()).
# `values` keeps the numbers behind each numeric column shown as categories,
# so it can go back to continuous exactly. A `types` entry over the level
# limit is not applied; its column is in `dropped`.
.write_metadata <- function(meta, dir, cell_ids, types = NULL) {
    if (!"cell_ID" %in% names(meta))
        stop("[push_metadata] metadata needs a `cell_ID` column matching the ",
            "cell IDs", call. = FALSE)
    if (is.null(cell_ids))
        stop("[push_metadata] the viewer has no cells to attach metadata to",
            call. = FALSE)
    # Dots and other characters break identifiers downstream; sanitising can
    # merge names, so make them unique again
    names(meta) <- make.unique(gsub("[^A-Za-z0-9_]", "_", names(meta)), sep = "_")
    row <- match(cell_ids, as.character(meta$cell_ID))
    unmatched <- nrow(meta) - sum(!is.na(row))
    if (all(is.na(row)))
        stop("[push_metadata] no cell_ID matches a cell in the viewer",
            call. = FALSE)
    if (unmatched > 0L)
        message("[push_metadata] ", unmatched, " metadata row(s) have no cell ",
            "in the viewer and are not shown")

    data_cols <- setdiff(names(meta), "cell_ID")
    if (!length(data_cols))
        stop("[push_metadata] metadata has no columns besides cell_ID", call. = FALSE)
    columns <- list()
    arrays  <- list()
    values  <- list()
    dropped <- character()
    for (cn in data_cols) {
        v <- meta[[cn]][row]
        numeric <- is.numeric(v)
        if (numeric && identical(unname(types[cn]), "categorical")) {
            lv <- .numeric_levels(v)
            if (length(lv) <= .max_numeric_levels) {
                enc <- .encode_numeric_categories(v, cn, lv)
                arrays[[cn]] <- enc$codes
                values[[cn]] <- lv
                columns[[length(columns) + 1L]] <- enc$entry
                next
            }
            warning("[push_metadata] `", cn, "` has ", length(lv), " distinct values, ",
                "more than the ", .max_numeric_levels, " that can be shown as ",
                "categories; it is continuous", call. = FALSE)
            dropped <- c(dropped, cn)
        }
        if (is.factor(v) || is.character(v) || is.logical(v)) {
            f <- if (is.factor(v)) droplevels(v) else factor(v)
            arrays[[cn]]  <- .category_codes(f)
            columns[[length(columns) + 1L]] <- list(name = cn,
                kind = "categorical", levels = as.list(levels(f)))
        } else {
            arrays[[cn]]  <- as.double(v)
            columns[[length(columns) + 1L]] <- list(name = cn, kind = "continuous",
                numeric = TRUE)
        }
    }

    path <- .new_meta_path(dir)
    arrow::write_parquet(as.data.frame(arrays, optional = TRUE), path)
    .prune_meta_files(dir, keep = path)
    list(msg = .meta_msg(path, length(cell_ids), columns), file = path,
        values = values, dropped = dropped)
}

# Rewrite the metadata file with one numeric column (`entry`, from the
# payload) changed to `type`. The other columns pass through as Arrow arrays,
# never as R vectors. `values`: the numbers behind the column's categories,
# when it is categorical now. Returns what .write_metadata() returns, for
# the new file.
.retype_meta <- function(file, entry, type, values = NULL, columns, n) {
    cn <- entry$name
    tb <- arrow::read_parquet(file, as_data_frame = FALSE, mmap = FALSE)
    v  <- as.vector(tb[[cn]])
    if (type == "categorical") {
        lv <- .numeric_levels(v)
        if (length(lv) > .max_numeric_levels)
            stop("[LensViewer] `", cn, "` has ", length(lv), " distinct values; ",
                "at most ", .max_numeric_levels, " can be shown as categories", call. = FALSE)
        enc <- .encode_numeric_categories(v, cn, lv)
        arr <- arrow::Array$create(enc$codes, type = arrow::int32())
        entry <- enc$entry
        values <- lv
    } else {
        arr <- arrow::Array$create(as.double(values[ifelse(v < 0L, NA, v + 1L)]))
        entry <- list(name = cn, kind = "continuous", numeric = TRUE)
        values <- NULL
    }
    tb <- tb$SetColumn(match(cn, names(tb)) - 1L, arrow::field(cn, arr$type),
        arrow::chunked_array(arr))
    path <- .new_meta_path(dirname(file))
    arrow::write_parquet(tb, path)
    rm(tb)
    .prune_meta_files(dirname(file), keep = path)
    columns[[match(cn, vapply(columns, `[[`, "", "name"))]] <- entry
    list(msg = .meta_msg(path, n, columns), file = path,
        values = stats::setNames(list(values), cn))
}

# One column of the metadata file as R sees it: continuous as doubles,
# categorical as a factor of its labels
.read_meta_column <- function(file, entry) {
    v <- arrow::read_parquet(file, col_select = entry$name, mmap = FALSE)[[1L]]
    if (entry$kind != "categorical") return(as.double(v))
    lv <- as.character(unlist(entry$levels))
    factor(lv[ifelse(v < 0L, NA, v + 1L)], levels = lv)
}

.meta_msg <- function(path, n, columns)
    list(url = paste0("session/metadata/", basename(path)), n = n, columns = columns)

# A fresh file name per write, so a browser never reads a cached older table
.new_meta_path <- function(dir) {
    stamp <- floor(as.numeric(Sys.time()) * 1000)
    repeat {
        path <- file.path(dir, sprintf("cell_meta_%.0f.parquet", stamp))
        if (!file.exists(path)) return(path)
        stamp <- stamp + 1
    }
}

# Once the new table is written, older ones go but the two latest: a tab may
# still be reading one
.prune_meta_files <- function(dir, keep) {
    old <- list.files(dir, pattern = "^cell_meta.*\\.parquet$", full.names = TRUE)
    old <- sort(old[basename(old) != basename(keep)], decreasing = TRUE)
    unlink(utils::tail(old, -2L))
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
