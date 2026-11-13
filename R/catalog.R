# The catalog: what the viewer can pull for the cells shown with
# GiottoClass::spatValues(), one source per slot item (cell metadata of a
# feature type, an expression matrix, a spatial enrichment, a dim reduction)
# with the names it holds. Built at load from the object shown, so it lists
# the snapshot's contents; kept until the next load. Pulls go through
# viewer$gobject() (the snapshot loaded again) and add columns to the
# viewer's metadata, not to the object.

# Sources for spatial unit `spat_unit` of giotto object `x`: a list of
# list(id, slot, feat_type, name, method, items). Names only: nothing here
# reads values.
.lens_catalog <- function(x, spat_unit) {
    sources <- list()
    add <- function(slot, feat_type, items, name = NULL, method = NULL) {
        items <- setdiff(as.character(items), "cell_ID")
        if (!length(items)) return()
        sources[[length(sources) + 1L]] <<- list(id = length(sources) + 1L, slot = slot,
            feat_type = feat_type, name = name, method = method, items = items)
    }
    cm <- GiottoClass::list_cell_metadata(x, spat_unit = spat_unit)
    for (ft in unique(cm$feat_type))
        add("cell_metadata", ft, colnames(GiottoClass::getCellMetadata(x,
            spat_unit = spat_unit, feat_type = ft, output = "cellMetaObj", copy_obj = FALSE)))
    ex <- GiottoClass::list_expression(x, spat_unit = spat_unit)
    for (i in seq_len(NROW(ex)))
        add("expression", ex$feat_type[[i]], GiottoClass::featIDs(GiottoClass::getExpression(x,
            spat_unit = spat_unit, feat_type = ex$feat_type[[i]], values = ex$name[[i]],
            output = "exprObj")), name = ex$name[[i]])
    en <- GiottoClass::list_spatial_enrichments(x, spat_unit = spat_unit)
    for (i in seq_len(NROW(en)))
        add("spatial_enrichment", en$feat_type[[i]], colnames(GiottoClass::getSpatialEnrichment(x,
            spat_unit = spat_unit, feat_type = en$feat_type[[i]], name = en$name[[i]],
            output = "spatEnrObj", copy_obj = FALSE)[]), name = en$name[[i]])
    dr <- GiottoClass::list_dim_reductions(x, data_type = "cells", spat_unit = spat_unit)
    for (i in seq_len(NROW(dr)))
        add("dimension_reduction", dr$feat_type[[i]], colnames(GiottoClass::getDimReduction(x,
            spat_unit = spat_unit, feat_type = dr$feat_type[[i]], reduction = "cells",
            reduction_method = dr$dim_type[[i]], name = dr$name[[i]], output = "dimObj")[]),
            name = dr$name[[i]], method = dr$dim_type[[i]])
    list(spat_unit = spat_unit, sources = sources)
}

# The page's copy. Expression matrices of one feature type usually share
# their features: a source whose items are an earlier one's says `same_as`
# instead of repeating a gene list.
.catalog_payload <- function(cat) {
    srcs <- cat$sources
    out <- lapply(seq_along(srcs), function(i) {
        s <- srcs[[i]]
        p <- Filter(Negate(is.null), s[c("id", "slot", "feat_type", "name", "method")])
        same <- Find(function(o) identical(o$items, s$items), srcs[seq_len(i - 1L)])
        if (is.null(same)) p$items <- as.list(s$items) else p$same_as <- same$id
        p
    })
    list(spat_unit = cat$spat_unit, sources = out)
}

# One row per source and item, as viewer$catalog() returns it
.catalog_table <- function(cat) {
    rows <- lapply(cat$sources, function(s) data.frame(source = s$id, slot = s$slot,
        feat_type = s$feat_type, name = s$name %||% NA_character_, item = s$items))
    if (!length(rows))
        return(data.frame(source = integer(), slot = character(), feat_type = character(),
            name = character(), item = character()))
    do.call(rbind, rows)
}

# What to pull, as a data.frame of source, item and type (NA: as the values
# are). `x`: rows of the catalog table (`source` and `item` columns, and
# `type` if given), or item names, which must each be in one source only.
# `types`: item -> type, for items whose rows give none.
.pull_items <- function(cat, x, types = NULL, site = "LensViewer$pull") {
    tbl <- .catalog_table(cat)
    if (is.character(x)) {
        hit <- tbl[tbl$item %in% x, , drop = FALSE]
        miss <- setdiff(x, hit$item)
        if (length(miss))
            stop("[", site, "] not in the catalog: ", paste(miss, collapse = ", "), call. = FALSE)
        many <- unique(hit$item[duplicated(hit$item)])
        if (length(many))
            stop("[", site, "] in more than one source: ", paste(many, collapse = ", "),
                "; pass rows of viewer$catalog() to pick one", call. = FALSE)
        x <- hit[c("source", "item")]
    } else if (is.data.frame(x) && all(c("source", "item") %in% names(x))) {
        key <- paste(x$source, x$item)
        bad <- !key %in% paste(tbl$source, tbl$item)
        if (any(bad))
            stop("[", site, "] not in the catalog: ",
                paste0(x$item[bad], " (source ", x$source[bad], ")", collapse = ", "), call. = FALSE)
    } else {
        stop("[", site, "] `x` must be item names or rows of viewer$catalog()", call. = FALSE)
    }
    if (!nrow(x)) stop("[", site, "] nothing to pull", call. = FALSE)
    type <- if ("type" %in% names(x)) as.character(x$type) else rep(NA_character_, nrow(x))
    type[type %in% c("", "auto")] <- NA_character_
    given <- .parse_col_types(types)
    use <- is.na(type) & x$item %in% names(given)
    type[use] <- given[x$item[use]]
    set <- !is.na(type)
    if (any(set)) type[set] <- unname(.parse_col_types(
        stats::setNames(as.list(type[set]), x$item[set])))
    out <- data.frame(source = as.integer(x$source), item = as.character(x$item), type = type)
    out[!duplicated(out[c("source", "item")]), , drop = FALSE]
}

# One svkey per source in `items` (from .pull_items()) and the viewer column
# each item becomes. spatValues() prefixes an item pulled from more than one
# source with its key's label; dim reduction axes are named
# <reduction>_<axis>, as push_metadata() names them, since every reduction
# calls its axes Dim.1, Dim.2, ...
.pull_plan <- function(cat, items) {
    ids <- unique(items$source)
    srcs <- cat$sources[ids]
    labels <- vapply(srcs, function(s) s$name %||% "meta", "")
    dup <- labels %in% labels[duplicated(labels)]
    labels[dup] <- paste0(vapply(srcs[dup], `[[`, "", "feat_type"), "_", labels[dup])
    labels <- make.unique(labels, sep = "_")
    shared <- unique(items$item[duplicated(items$item)])
    keys <- list()
    cols <- list()
    for (k in seq_along(srcs)) {
        s <- srcs[[k]]
        rows <- items[items$source == s$id, , drop = FALSE]
        args <- list(feats = rows$item, spat_unit = cat$spat_unit, feat_type = s$feat_type)
        args <- c(args, switch(s$slot,
            cell_metadata       = list(slot = "cell_metadata"),
            expression          = list(expression_values = s$name),
            spatial_enrichment  = list(spat_enr_name = s$name),
            dimension_reduction = list(dim_reduction_to_use = s$method,
                dim_reduction_name = s$name)))
        keys[[labels[[k]]]] <- do.call(GiottoClass::svkey, args)
        result <- ifelse(rows$item %in% shared, paste0(labels[[k]], "_", rows$item), rows$item)
        column <- if (s$slot == "dimension_reduction")
            paste0(s$name, "_", match(rows$item, s$items)) else result
        cols[[k]] <- data.frame(result = result, column = .meta_name(column), type = rows$type)
    }
    list(keys = keys, cols = do.call(rbind, cols))
}
