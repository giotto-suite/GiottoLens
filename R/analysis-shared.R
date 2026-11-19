# ── Steps shared by analyses ────────────────────────────────────────────────
#
# Builders for steps that several catalog entries use. A step built here
# needs a unique id in its entry; `input` is the id of the step it reads.

# The giotto object an analysis reads: the result of the Preprocessing tab's
# Cell types step, or the loaded object
.step_source <- function(label = "Expression", default = "preprocess") .with_help(list(
    label = label, input = NULL, kind = "source",
    fun = "",
    params = list(.param("from", "expression from", list(
        .ch("preprocess", "Preprocessing tab", value = "preprocess"),
        .ch("object", "loaded object", value = "object")), default),
        .values_param("normalized")),
    run = function(g, p) g,
    result = function(g, p, before) {
        ex <- as.data.frame(GiottoClass::list_expression(g))
        vals <- .lens_values(p)
        list(summary = sprintf("%d cells, %d features (%s, %s values)",
                length(GiottoClass::spatIDs(g)), length(GiottoClass::featIDs(g)),
                if (p$from == "preprocess") "Preprocessing tab" else "loaded object", vals),
            stop_below = if (!vals %in% ex$name) paste0("no '", vals, "' expression; ",
                "available: ", paste(unique(ex$name), collapse = ", ")))
    },
    code = function(p, up) ""
), list(
    from = paste0(
        "The data this analysis starts from. Preprocessing tab: the cells and values after the ",
        "Preprocessing steps (QC filter, normalization, clusters). Loaded object: the object as ",
        "it was loaded."),
    expression_values = paste0(
        "The expression values the steps of this analysis read: those of the loaded object, ",
        "and with Preprocessing tab those of the Normalize step. Empty: normalized.")))

# Cells with a value in a categorical column, as `lens_group`
.step_groups <- function(label = "Cell types", input = NULL) .with_help(list(
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
        if (length(p$cells)) "g <- subsetGiotto(g, cell_ids = viewer$analysis()$region())" else ""
), list(
    column = paste0(
        "The cell metadata label used for cell types, for example cell_type or leiden_clus. ",
        "Labels marked (Preprocessing) come from the Preprocessing tab. Cells without a value for ",
        "the label are left out.")))

# The spatial network a step uses: that of its own `network` parameter, else
# of the nearest step above with one (`name`, or `<method>_network`, for a
# new network)
.network_of <- function(p, up = p$up) {
    for (a in c(list(p), up)) {
        v <- a$network
        if (!is.character(v) || length(v) != 1L || !nzchar(v)) next
        if (!identical(v, "new")) return(v)
        nm <- a$name
        return(if (is.character(nm) && length(nm) == 1L && nzchar(nm)) nm
            else paste0(a$method, "_network"))
    }
    "spatial_network"
}

# A spatial network: a new one, stored under `name` (empty: Giotto's
# default, `<method>_network`), or one of the loaded object or of another
# analysis, by name (`network`). RTriangle and its settings are offered when
# the RTriangle package is installed.
.step_network <- function(label = "Spatial network", input) {
    rtriangle <- requireNamespace("RTriangle", quietly = TRUE)
    params <- c(list(
        list(id = "network", label = "network", type = "spatial_network", choices = list(),
            default = "new"),
        .param("method", "method", list(.ch("kNN", value = "kNN"),
            .ch("Delaunay", value = "Delaunay"), .ch("radius", value = "radius")), "kNN"),
        .num("k", "k (kNN)", 20, c(2, 50), min = 1, integer = TRUE),
        .num("radius", "radius", 30, c(1, 200), min = 0.001, log = TRUE),
        .advanced(.num("maximum_distance_knn", "max distance (kNN)", "auto", c(1, 200),
            min = 0, auto = TRUE)),
        .advanced(.param("knn_method", "kNN search", list(.ch("dbscan", value = "dbscan")),
            "dbscan")),
        .advanced(.num("maximum_distance_delaunay", "max distance (Delaunay)", "auto",
            c(1, 200), min = 0, auto = TRUE)),
        utils::modifyList(.advanced(.param("delaunay_method", "Delaunay method", c(list(
            .ch("deldir", value = "deldir"),
            .ch("delaunayn_geometry", value = "delaunayn_geometry")),
            if (rtriangle) list(.ch("RTriangle", value = "RTriangle"))),
            "delaunayn_geometry")), list(code_default = "deldir")),
        .advanced(.text_param("options", "Qhull options", default = "Pp"))),
        if (rtriangle) list(
            .advanced(.yes_no("Y", "no boundary Steiner points")),
            .advanced(.yes_no("j", "drop unused vertices")),
            .advanced(.num("S", "max Steiner points", 0, c(0, 100), min = 0, integer = TRUE))),
        list(
        .advanced(.num("minimum_k", "minimum neighbors", 0, c(0, 20), min = 0,
            integer = TRUE)),
        .advanced(.param("dimensions", "dimensions", list(.ch("all", value = "all"),
            .ch(1:2, "x and y", value = "1:2")), "all")),
        .name_param("", "method_network, e.g. kNN_network")
    ))
    show <- c(list(
        k = list(method = "kNN"), maximum_distance_knn = list(method = "kNN"),
        knn_method = list(method = "kNN"), radius = list(method = "radius"),
        maximum_distance_delaunay = list(method = "Delaunay"),
        delaunay_method = list(method = "Delaunay"),
        options = list(method = "Delaunay", delaunay_method = "delaunayn_geometry")),
        if (rtriangle) list(
            Y = list(method = "Delaunay", delaunay_method = "RTriangle"),
            j = list(method = "Delaunay", delaunay_method = "RTriangle"),
            S = list(method = "Delaunay", delaunay_method = "RTriangle")))
    for (id in setdiff(vapply(params, `[[`, "", "id"), "network"))
        show[[id]] <- c(list(network = "new"), show[[id]])

    .with_show(.with_help(list(
    label = label, input = input,
    fun = "createSpatialNetwork",
    params = params,
    run = function(g, p) {
        name <- .lens_net(p)
        if (!identical(p$network, "new")) return(.lens_network(g, NULL, NULL, name))
        args <- list(method = p$method, dimensions = p$dimensions,
            k = p$k, maximum_distance_knn = p$maximum_distance_knn, knn_method = p$knn_method,
            radius = p$radius, delaunay_method = p$delaunay_method,
            maximum_distance_delaunay = if (is.null(p$maximum_distance_delaunay)) "auto"
                else p$maximum_distance_delaunay,
            options = p$options, Y = if (is.null(p$Y)) TRUE else p$Y,
            j = if (is.null(p$j)) TRUE else p$j, S = if (is.null(p$S)) 0 else p$S,
            minimum_k = p$minimum_k)
        .lens_network(g, args, function(g) do.call(Giotto::createSpatialNetwork,
            c(list(g, name = name), args, list(verbose = FALSE))), name)
    },
    result = function(g, p, before) {
        name <- .lens_net(p)
        n <- GiottoClass::getSpatialNetwork(g, name = name, output = "networkDT")
        list(summary = sprintf("%s: %d links, median length %.1f", name, nrow(n),
                if (nrow(n)) stats::median(n$distance) else NA_real_),
            stop_below = if (!nrow(n)) "the network has no links")
    },
    code = function(p, up) if (!identical(p$network, "new")) "" else
        paste0("g <- createSpatialNetwork(g, ", paste(c(
        .code_args(params, p, c("method", "k", "radius", "maximum_distance_knn", "knn_method",
            "delaunay_method", "maximum_distance_delaunay", "options", "Y", "j", "S",
            "minimum_k", "dimensions"), show),
        paste0("name = ", .code_value(.network_of(p)))), collapse = ", "), ")")
), list(
    network = paste0(
        "The spatial network the steps below use. new: a network made by this step with the ",
        "settings below. Otherwise a network of the loaded object or of another analysis, by ",
        "name. Default: a network of the loaded object (Delaunay_network, kNN_network or ",
        "spatial_network first), else new."),
    name = paste0(
        "The name the new network is stored under in the giotto object. Empty: the method and ",
        "_network, for example kNN_network."),
    method = paste0(
        "How each cell is connected to its spatial neighbors. kNN: each cell is connected to its ",
        "k nearest cells. Delaunay: cells are connected to the cells next to them in a ",
        "triangulation of the cell centers (about 6 per cell). radius: each cell is connected ",
        "to all cells within the radius, so cells in dense areas get more neighbors."),
    k = paste0(
        "Number of nearest cells each cell is connected to (kNN only). For example, k = 20 ",
        "connects each cell to the 20 cells closest to it. Higher values cover a wider area ",
        "around each cell; lower values only the direct neighbors."),
    radius = paste0(
        "Distance within which cells are connected, in the units of the cell coordinates ",
        "(microns for MERSCOPE and Xenium; radius only). For example, 30 connects each cell to ",
        "every cell whose center is within 30 µm. Larger values give more neighbors per cell."),
    maximum_distance_knn = paste0(
        "Longest connection allowed between two cells, in the units of the cell coordinates ",
        "(microns for MERSCOPE and Xenium; kNN only). For example, 30 removes connections between ",
        "cells more than 30 µm apart, so cells across a gap in the tissue are not connected. ",
        "Empty: no limit."),
    knn_method = paste0(
        "How the nearest cells are found (kNN only). dbscan: an exact search."),
    maximum_distance_delaunay = paste0(
        "Longest connection kept in the Delaunay network, in the units of the cell coordinates. ",
        "For example, 50 removes triangle edges longer than 50 µm, such as those across gaps ",
        "or along the tissue edge. Lower values remove more connections. Empty: the upper ",
        "whisker of a boxplot of all edge lengths (about the third quartile plus 1.5 times the ",
        "interquartile range)."),
    delaunay_method = paste0(
        "The program that computes the triangulation. All give the same network. ",
        "delaunayn_geometry: fast on large sections. deldir: slow above a few thousand cells. ",
        "RTriangle: listed when the RTriangle package is installed."),
    options = paste0(
        "For delaunayn_geometry. Options passed to Qhull, the triangulation program, as one ",
        "string. For example, Pp does not report precision warnings. See the Qhull ",
        "documentation for other options."),
    Y = paste0(
        "For RTriangle. Whether adding extra points (Steiner points) on the boundary of the ",
        "triangulation is prohibited."),
    j = paste0(
        "For RTriangle. Whether points that are not part of the final triangulation are ",
        "removed from the output."),
    S = paste0(
        "For RTriangle. The largest number of extra points (Steiner points) added to the ",
        "triangulation. For example, 0 adds none."),
    minimum_k = paste0(
        "Minimum number of neighbors each cell keeps when a maximum distance removes ",
        "connections. For example, 2 keeps each cell's 2 nearest neighbors even when they are ",
        "farther than the maximum distance. 0: no minimum."),
    dimensions = paste0(
        "Coordinates used to measure distances between cells. all: every spatial coordinate ",
        "of the object (x, y, and z when present). x and y: the two in-plane coordinates."))),
    show)
}

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
