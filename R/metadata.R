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
#' @param cols       Character vector of metadata columns to include.
#'                   `NULL` (default) includes all columns.
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

    if (!is.null(cols))
        meta <- meta[, unique(c(id_col, intersect(cols, names(meta)))), drop = FALSE]

    if (!is.null(dimreds)) {
        # Build lookup table: name → dim_type
        dr_registry <- tryCatch(
            as.data.frame(GiottoClass::list_dim_reductions(x)),
            error = function(e) NULL
        )

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
                    warning("prep_meta: could not load '", dr_row$name, "' — ",
                            conditionMessage(e), call. = FALSE)
                    NULL
                }
            )
            if (is.null(dr_mat)) next

            d <- dims[dims <= ncol(dr_mat)]
            if (!length(d)) next

            dr_sub            <- as.data.frame(dr_mat[, d, drop = FALSE])
            colnames(dr_sub)  <- paste0(dr_row$name, "_", seq_along(d))
            dr_sub[[id_col]]  <- rownames(dr_mat)

            meta <- merge(meta, dr_sub, by = id_col, all.x = TRUE)
        }
    }

    meta
}
