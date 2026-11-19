# ── Niches ───────────────────────────────────────────────────────────────────

.analysis_entry_niches <- function() list(
    id = "niches", label = "Niches", order = 40, auto = FALSE,
    brief = "Groups cells by the cell types of their neighbors.",
    description = paste(
        "Links each cell to its neighbors in a spatial network and computes, for each",
        "cell, the proportion of each cell type among the cell and its neighbors.",
        "k-means clustering of these proportions gives the niches, numbered from the",
        "largest. The number of niches is the one with the highest mean silhouette width",
        "on a sample of cells, unless set. The heatmap shows the mean proportion of each",
        "cell type in each niche, and the cells are colored by niche."),
    inputs = c("a categorical cell type column (object or Preprocessing tab)",
        "spatial locations"),
    outputs = c("nc_niche (cell metadata)",
        "mean cell type proportions per niche (heatmap)"),
    steps = list(
        nc_groups = .step_groups(input = NULL),
        nc_network = .step_network(input = "nc_groups"),
        nc_proportions = list(
            label = "Neighborhood composition", input = "nc_network",
            fun = "calculateSpatCellMetadataProportions",
            params = list(),
            run = function(g, p) suppressWarnings(
                Giotto::calculateSpatCellMetadataProportions(g,
                    spat_network = .lens_net(p), metadata_column = "lens_group",
                    name = "nc_proportion")),
            result = function(g, p, before) {
                e <- GiottoClass::getSpatialEnrichment(g, name = "nc_proportion",
                    output = "data.table")
                list(summary = sprintf("%d cells, %d cell types", nrow(e), ncol(e) - 1L),
                    stop_below = if (nrow(e) < 2L) "fewer than two cells have neighbors")
            },
            code = function(p, up) {
                col <- Find(Negate(is.null), lapply(up, `[[`, "column_name"))
                paste0("g <- calculateSpatCellMetadataProportions(g, spat_network = ",
                    "", .code_value(.network_of(p, up)), ", metadata_column = ",
                    paste(deparse(col), collapse = ""), ", name = \"nc_proportion\")")
            }
        ),
        nc_kmeans = list(
            label = "Niche clusters", input = "nc_proportions",
            fun = "kmeans",
            params = list(
                utils::modifyList(.num("k", "niches (k)", "auto", c(2, 20), min = 1,
                    integer = TRUE, auto = TRUE), list(own_help = TRUE)),
                .num("k_max", "most niches scored", 15, c(3, 40), min = 3, max = 100,
                    integer = TRUE),
                .num("auto_cells", "cells scored", 3000, c(500, 10000), min = 100,
                    max = 20000, integer = TRUE, log = TRUE),
                .advanced(.num("iter_max", "max iterations", 1000, c(10, 5000), min = 1,
                    integer = TRUE, log = TRUE)),
                .advanced(.num("nstart", "random starts", 100, c(1, 500), min = 1,
                    integer = TRUE, log = TRUE)),
                .advanced(.param("algorithm", "k-means algorithm", lapply(c("Hartigan-Wong",
                    "Lloyd", "Forgy", "MacQueen"), function(m) .ch(m, value = m)),
                    "Hartigan-Wong")),
                .advanced(.num("seed", "seed", 1234, c(1, 10000), min = 0, integer = TRUE)),
                .name_param("nc_niche")
            ),
            run = function(g, p) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g,
                    name = "nc_proportion", output = "data.table"))
                m <- as.matrix(e[setdiff(names(e), "cell_ID")])
                rownames(m) <- e$cell_ID
                set.seed(p$seed)
                idx <- if (nrow(m) > p$auto_cells) sort(sample.int(nrow(m), p$auto_cells))
                    else seq_len(nrow(m))
                x <- m[idx, , drop = FALSE]
                ks <- seq.int(2L, max(2L, min(p$k_max, nrow(unique(x)) - 1L)))
                d <- as.matrix(stats::dist(x))
                sil <- vapply(seq_along(ks), function(i) {
                    .lens_progress(i - 1L, length(ks) + 1L, "niche counts scored")
                    set.seed(p$seed)
                    cl <- stats::kmeans(x, centers = ks[[i]], iter.max = p$iter_max,
                        nstart = min(p$nstart, 10L),
                        algorithm = p$algorithm %||% "Hartigan-Wong")$cluster
                    .lens_silhouette(d, cl)
                }, 1)
                rm(d)
                k <- if (is.null(p$k)) ks[[which.max(sil)]] else p$k
                .lens_keep(list(ks = ks, silhouette = sil, cells = length(idx),
                    auto = is.null(p$k)))
                .lens_progress(length(ks), length(ks) + 1L, "final k-means")
                set.seed(p$seed)
                km <- stats::kmeans(m, centers = k, iter.max = p$iter_max,
                    nstart = p$nstart, algorithm = p$algorithm %||% "Hartigan-Wong")
                rank <- order(-km$size, seq_along(km$size))
                nm <- if (nzchar(p$name %||% "")) p$name else "nc_niche"
                d <- data.table::data.table(cell_ID = rownames(m))
                d[[nm]] <- paste("niche", match(km$cluster, rank))
                GiottoClass::addCellMetadata(g, new_metadata = d, by_column = TRUE,
                    column_cell_ID = "cell_ID")
            },
            result = function(g, p, before) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g,
                    name = "nc_proportion", output = "data.table"))
                types <- setdiff(names(e), "cell_ID")
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                nm <- if (nzchar(p$name %||% "")) p$name else "nc_niche"
                niche <- cm[[nm]][match(e$cell_ID, cm$cell_ID)]
                lv <- paste("niche", sort(unique(as.integer(sub("niche ", "", niche,
                    fixed = TRUE)))))
                comp <- do.call(rbind, lapply(lv, function(k) {
                    rows <- which(niche == k)
                    data.frame(niche = k, cell_type = types,
                        proportion = unname(colMeans(as.matrix(e[rows, types, drop = FALSE]))),
                        cells = length(rows))
                }))
                sizes <- table(factor(niche, levels = lv))
                kept <- .lens_kept()
                meta <- data.frame(cell_ID = as.character(cm$cell_ID))
                meta[[nm]] <- as.character(cm[[nm]])
                list(meta = meta, composition = comp, order = lv,
                    k_scores = if (!is.null(kept$silhouette))
                        data.frame(k = kept$ks, silhouette = kept$silhouette,
                            used = kept$ks == length(lv)),
                    summary = paste0(length(lv), " niches",
                        if (isTRUE(kept$auto)) sprintf(
                            " (silhouette %.2f on %d cells, %d to %d scored)",
                            max(kept$silhouette), kept$cells, min(kept$ks), max(kept$ks))
                        else if (length(lv) %in% kept$ks) sprintf(" (silhouette %.2f)",
                            kept$silhouette[kept$ks == length(lv)]),
                        ": ", paste(sprintf("%s %d", names(sizes), as.integer(sizes)),
                            collapse = ", ")))
            },
            view = function(res, p) {
                panels <- list(list(id = "nc_composition", title = "Niche composition",
                    spec = .nc_composition_spec(res$composition, res$order)))
                if (!is.null(res$k_scores))
                    panels <- c(panels, list(list(id = "nc_k", title = "Niches: number",
                        spec = .k_scores_spec(res$k_scores, "niches"))))
                list(panels = panels,
                    color = if (nzchar(p$name %||% "")) p$name else "nc_niche")
            },
            pick = function(value, res, p) {
                k <- unlist(value$k)
                if (length(k)) list(set = list(k = as.integer(k[[1L]])))
            },
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                paste0(
                    "prop <- as.data.frame(getSpatialEnrichment(g, name = \"nc_proportion\", ",
                    "output = \"data.table\"))\n",
                    "prop_matrix <- as.matrix(prop[setdiff(names(prop), \"cell_ID\")])\n",
                    "rownames(prop_matrix) <- prop$cell_ID\n",
                    if (is.null(p$k)) paste0(
                        "set.seed(", arg(p$seed), ")\n",
                        "scored <- prop_matrix[sort(sample.int(nrow(prop_matrix), min(",
                        arg(p$auto_cells), ", nrow(prop_matrix)))), ]\n",
                        "scored_dist <- dist(scored)\n",
                        "ks <- 2:", arg(p$k_max), "\n",
                        "silhouette <- sapply(ks, function(k) {\n",
                        "    set.seed(", arg(p$seed), ")\n",
                        "    cl <- kmeans(scored, centers = k, iter.max = ", arg(p$iter_max),
                        ", nstart = ", arg(min(p$nstart, 10L)),
                        if (!identical(p$algorithm %||% "Hartigan-Wong", "Hartigan-Wong"))
                            paste0(", algorithm = ", arg(p$algorithm)), ")$cluster\n",
                        "    mean(cluster::silhouette(cl, scored_dist)[, \"sil_width\"])\n",
                        "})\n",
                        "k <- ks[which.max(silhouette)]\n"),
                    "set.seed(", arg(p$seed), ")\n",
                    "prop_kmeans <- kmeans(prop_matrix, centers = ",
                    if (is.null(p$k)) "k" else arg(p$k),
                    ", iter.max = ", arg(p$iter_max), ", nstart = ", arg(p$nstart),
                    if (!identical(p$algorithm %||% "Hartigan-Wong", "Hartigan-Wong"))
                        paste0(", algorithm = ", arg(p$algorithm)), ")\n",
                    "rank <- order(-prop_kmeans$size, seq_along(prop_kmeans$size))\n",
                    "g <- addCellMetadata(g, new_metadata = data.table::data.table(",
                    "cell_ID = rownames(prop_matrix), ",
                    {
                        nm <- if (nzchar(p$name %||% "")) p$name else "nc_niche"
                        if (identical(make.names(nm), nm)) nm else paste0("`", nm, "`")
                    },
                    " = paste(\"niche\", match(prop_kmeans$cluster, rank))), ",
                    "by_column = TRUE, column_cell_ID = \"cell_ID\")")
            }
        )
    )
)

# Heatmap of the mean cell type proportions (columns) of each niche (rows)
.nc_composition_spec <- function(d, order) {
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "mean cell type proportion of neighbors", width = "container",
        height = "container",
        data = list(values = d),
        mark = list(type = "rect", tooltip = TRUE),
        encoding = list(
            x = list(field = "cell_type", type = "nominal", title = NULL),
            y = list(field = "niche", type = "nominal", sort = as.list(order), title = NULL),
            color = list(field = "proportion", type = "quantitative", title = "proportion",
                scale = list(scheme = "viridis", domain = list(0, 1))),
            tooltip = list(
                list(field = "niche", type = "nominal"),
                list(field = "cell_type", type = "nominal", title = "cell type"),
                list(field = "proportion", type = "quantitative", format = ".2f"),
                list(field = "cells", type = "quantitative", title = "cells in niche")))
    )
}

.analysis_help_niches <- function() list(
    nc_kmeans = list(
        name = paste0(
            "The name of the cell metadata column that holds the niches. Empty: nc_niche."),
        k = paste0(
            "Number of niches. Each cell is described by the proportions of cell types among its ",
            "spatial neighbors, and cells with similar proportions are grouped by k-means into ",
            "this many niches. More niches split the tissue into smaller, more specific regions. ",
            "auto: k-means is run on a sample of cells for every number from 2 to the most niches ",
            "tried, each result is scored by the mean silhouette width (how much closer each cell ",
            "is to the cells of its own niche than to those of the nearest other niche), and the ",
            "highest score is used for all cells."),
        k_max = paste0(
            "The largest number of niches scored in the silhouette chart, and tried by auto. For ",
            "example, 15 scores 2 to 15 niches. A click on a point of the chart uses that number ",
            "of niches."),
        auto_cells = paste0(
            "The number of cells, drawn at random with the seed, that the numbers of niches are ",
            "scored on in the silhouette chart. More cells give a steadier choice but take more ",
            "time and memory (a 3,000 cell sample uses about 70 MB)."),
        iter_max = paste0(
            "Maximum number of iterations for each k-means run. Raise it if k-means does not ",
            "converge."),
        nstart = paste0(
            "Number of k-means runs from different random starting points; the run with the ",
            "tightest groups is kept. More runs give more stable niches but take longer."),
        algorithm = paste0(
            "Method k-means uses to move cells between niches. Hartigan-Wong: moves single ",
            "cells when that makes the niches tighter. Lloyd and Forgy: assign all cells to the ",
            "nearest niche center, then update the centers, in rounds. MacQueen: updates a niche ",
            "center each time a cell moves. Lloyd, Forgy and MacQueen may need more iterations ",
            "to converge."),
        seed = paste0(
            "Random seed for k-means. The same seed and parameters always give the same niches."))
)

