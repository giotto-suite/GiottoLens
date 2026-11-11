# ── Niches ───────────────────────────────────────────────────────────────────

.analysis_entry_niches <- function() list(
    id = "niches", label = "Niches", order = 40, auto = FALSE,
    brief = "Groups cells by the cell types of their neighbors.",
    description = paste(
        "Links each cell to its neighbors in a spatial network and computes, for each",
        "cell, the proportion of each cell type among the cell and its neighbors.",
        "k-means clustering of these proportions gives the niches, numbered from the",
        "largest. The heatmap shows the mean proportion of each cell type in each niche."),
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
                    spat_network = "lens_spatial", metadata_column = "lens_group",
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
                    "\"lens_spatial\", metadata_column = ",
                    paste(deparse(col), collapse = ""), ", name = \"nc_proportion\")")
            }
        ),
        nc_kmeans = list(
            label = "Niche clusters", input = "nc_proportions",
            fun = "kmeans",
            params = list(
                .num("k", "niches (k)", 7, c(2, 20), min = 1, integer = TRUE),
                .num("iter_max", "max iterations", 1000, c(10, 5000), min = 1,
                    integer = TRUE, log = TRUE),
                .num("nstart", "random starts", 100, c(1, 500), min = 1, integer = TRUE,
                    log = TRUE),
                .num("seed", "seed", 1234, c(1, 10000), min = 0, integer = TRUE)
            ),
            run = function(g, p) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g,
                    name = "nc_proportion", output = "data.table"))
                m <- as.matrix(e[setdiff(names(e), "cell_ID")])
                rownames(m) <- e$cell_ID
                set.seed(p$seed)
                km <- stats::kmeans(m, centers = p$k, iter.max = p$iter_max,
                    nstart = p$nstart)
                rank <- order(-km$size, seq_along(km$size))
                GiottoClass::addCellMetadata(g, new_metadata = data.table::data.table(
                    cell_ID = rownames(m), nc_niche = paste("niche", match(km$cluster, rank))),
                    by_column = TRUE, column_cell_ID = "cell_ID")
            },
            result = function(g, p, before) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g,
                    name = "nc_proportion", output = "data.table"))
                types <- setdiff(names(e), "cell_ID")
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                niche <- cm$nc_niche[match(e$cell_ID, cm$cell_ID)]
                lv <- paste("niche", seq_len(p$k))
                lv <- lv[lv %in% niche]
                comp <- do.call(rbind, lapply(lv, function(k) {
                    rows <- which(niche == k)
                    data.frame(niche = k, cell_type = types,
                        proportion = unname(colMeans(as.matrix(e[rows, types, drop = FALSE]))),
                        cells = length(rows))
                }))
                sizes <- table(factor(niche, levels = lv))
                list(meta = data.frame(cell_ID = as.character(cm$cell_ID),
                        nc_niche = as.character(cm$nc_niche)),
                    composition = comp, order = lv,
                    summary = paste0(length(lv), " niches: ",
                        paste(sprintf("%s %d", names(sizes), as.integer(sizes)),
                            collapse = ", ")))
            },
            view = function(res, p) list(panels = list(list(id = "nc_composition",
                title = "Niche composition",
                spec = .nc_composition_spec(res$composition, res$order)))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                paste0(
                    "prop <- as.data.frame(getSpatialEnrichment(g, name = \"nc_proportion\", ",
                    "output = \"data.table\"))\n",
                    "prop_matrix <- as.matrix(prop[setdiff(names(prop), \"cell_ID\")])\n",
                    "rownames(prop_matrix) <- prop$cell_ID\n",
                    "set.seed(", arg(p$seed), ")\n",
                    "prop_kmeans <- kmeans(prop_matrix, centers = ", arg(p$k),
                    ", iter.max = ", arg(p$iter_max), ", nstart = ", arg(p$nstart), ")\n",
                    "rank <- order(-prop_kmeans$size, seq_along(prop_kmeans$size))\n",
                    "g <- addCellMetadata(g, new_metadata = data.table::data.table(",
                    "cell_ID = rownames(prop_matrix), ",
                    "nc_niche = paste(\"niche\", match(prop_kmeans$cluster, rank))), ",
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
