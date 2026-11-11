# ── Steps shared by analyses ────────────────────────────────────────────────
#
# Builders for steps that several catalog entries use. A step built here
# needs a unique id in its entry; `input` is the id of the step it reads.

# The giotto object an analysis reads: the result of the Preprocessing tab's
# Cell types step, or the loaded object
.step_source <- function(label = "Expression", default = "preprocess") list(
    label = label, input = NULL, kind = "source",
    fun = "",
    params = list(.param("from", "expression from", list(
        .ch("preprocess", "Preprocessing tab", value = "preprocess"),
        .ch("object", "loaded object", value = "object")), default)),
    run = function(g, p) g,
    result = function(g, p, before) {
        ex <- as.data.frame(GiottoClass::list_expression(g))
        has <- "normalized" %in% ex$name
        list(summary = sprintf("%d cells, %d features (%s)",
                length(GiottoClass::spatIDs(g)), length(GiottoClass::featIDs(g)),
                if (p$from == "preprocess") "Preprocessing tab" else "loaded object"),
            stop_below = if (!has) paste("no normalized expression: run the Preprocessing",
                "tab or load an object with normalized values"))
    },
    code = function(p, up) ""
)

# Cells with a value in a categorical column, as `lens_group`
.step_groups <- function(label = "Cell types", input = NULL) list(
    label = label, input = input, kind = "groups",
    fun = "addCellMetadata",
    params = list(.col_param("column", "cell type column")),
    run = function(g, p) {
        d <- p$groups
        ids <- intersect(GiottoClass::spatIDs(g), d$cell_ID)
        if (length(p$cells)) ids <- intersect(ids, p$cells)
        if (length(ids) < length(GiottoClass::spatIDs(g)))
            g <- GiottoClass::subsetGiotto(g, cell_ids = ids, verbose = FALSE)
        ids <- GiottoClass::spatIDs(g)
        GiottoClass::addCellMetadata(g, new_metadata = data.table::data.table(
            cell_ID = ids, lens_group = d$group[match(ids, d$cell_ID)]),
            by_column = TRUE, column_cell_ID = "cell_ID")
    },
    result = function(g, p, before) {
        tab <- table(GiottoClass::pDataDT(g)$lens_group)
        list(summary = sprintf("%d cells in %d types (%s)", sum(tab), length(tab),
                p$column_name),
            stop_below = if (length(tab) < 2L) "needs at least two cell types")
    },
    code = function(p, up)
        if (length(p$cells)) "g <- subsetGiotto(g, cell_ids = viewer$analysis$region())" else ""
)

# A spatial network named "lens_spatial"
.step_network <- function(label = "Spatial network", input) list(
    label = label, input = input,
    fun = "createSpatialNetwork",
    params = list(
        .param("method", "method", list(.ch("kNN", value = "kNN"),
            .ch("Delaunay", value = "Delaunay")), "kNN"),
        .num("k", "k (kNN)", 20, c(2, 50), min = 1, integer = TRUE),
        .num("maximum_distance_knn", "max distance (kNN)", "auto", c(1, 200),
            min = 0, auto = TRUE)
    ),
    run = function(g, p) {
        if (p$method == "kNN") Giotto::createSpatialNetwork(g, method = "kNN",
            k = p$k, maximum_distance_knn = p$maximum_distance_knn,
            name = "lens_spatial", verbose = FALSE)
        else Giotto::createSpatialNetwork(g, method = "Delaunay",
            name = "lens_spatial", verbose = FALSE)
    },
    result = function(g, p, before) {
        n <- GiottoClass::getSpatialNetwork(g, name = "lens_spatial",
            output = "networkDT")
        list(summary = sprintf("%d links, median length %.1f", nrow(n),
                if (nrow(n)) stats::median(n$distance) else NA_real_),
            stop_below = if (!nrow(n)) "the network has no links")
    },
    code = function(p, up) {
        arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v), collapse = "")
        if (identical(p$method, "kNN"))
            paste0("g <- createSpatialNetwork(g, method = \"kNN\", k = ", arg(p$k),
                if (!is.null(p$maximum_distance_knn))
                    paste0(", maximum_distance_knn = ", arg(p$maximum_distance_knn)),
                ", name = \"lens_spatial\")")
        else "g <- createSpatialNetwork(g, method = \"Delaunay\", name = \"lens_spatial\")"
    }
)

# A table for a step's `view()`: rows sorted by `sort`, at most `max_rows`;
# `feat` names the column whose values are genes (a click colors the cells)
.analysis_table <- function(data, id, title, feat = NULL, sort = NULL, decreasing = TRUE,
                            note = NULL, max_rows = 5000L) {
    data <- as.data.frame(data)
    n <- nrow(data)
    if (!is.null(sort) && sort %in% names(data))
        data <- data[order(data[[sort]], decreasing = decreasing, na.last = TRUE), , drop = FALSE]
    if (n > max_rows) data <- data[seq_len(max_rows), , drop = FALSE]
    cols <- lapply(data, function(x) {
        if (is.factor(x)) x <- as.character(x)
        if (is.numeric(x)) x <- signif(x, 4)
        lapply(x, function(v) if (is.na(v) || (is.numeric(v) && !is.finite(v))) NULL else v)
    })
    list(id = id, title = title, columns = as.list(names(data)), data = unname(cols),
        feat = feat, n = n, shown = nrow(data), note = note)
}
