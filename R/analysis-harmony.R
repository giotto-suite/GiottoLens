# ── Integration (Harmony) ────────────────────────────────────────────────────

.analysis_entry_harmony <- function() {
    batches <- .step_groups(label = "Batches", input = "hm_source")
    batches$params <- list(.col_param("column", "batch column"))
    batches$result <- function(g, p, before) {
        tab <- table(GiottoClass::pDataDT(g)$lens_group)
        list(summary = sprintf("%d cells in %d batches (%s)", sum(tab), length(tab),
                p$column_name),
            stop_below = if (length(tab) < 2L) paste0("the batch column '", p$column_name,
                "' has one value: Harmony needs at least two batches"))
    }
    list(
        id = "harmony", label = "Integration (Harmony)", order = 90, auto = FALSE,
        brief = "Corrects the PCA for batches with Harmony, then clusters and embeds the cells.",
        description = paste(
            "Runs Harmony on the PCA of the expression with a categorical column as the batch",
            "and builds a nearest network, Leiden clusters and a UMAP on the corrected",
            "dimensions. Clusters that hold cells of every batch in about their overall",
            "shares are shared between batches; clusters made of one batch are",
            "batch-specific."),
        inputs = c("normalized expression with a PCA (object or Preprocessing tab)",
            "a categorical batch column with at least two values"),
        outputs = c("hm_leiden, hm_umap_1 and hm_umap_2 (cell metadata)",
            "batch shares per cluster (bar chart and table)", "UMAP by batch"),
        steps = list(
            hm_source = .step_source(),
            hm_batch = batches,
            hm_harmony = list(
                label = "Harmony", input = "hm_batch",
                fun = "runGiottoHarmony",
                params = list(.pcs("dimensions_to_use", "PCs for Harmony")),
                run = function(g, p) {
                    dr <- as.data.frame(GiottoClass::list_dim_reductions(g))
                    if (!any(dr$dim_type == "pca" & dr$name == "pca"))
                        stop("no PCA named 'pca': run the Preprocessing tab or load an",
                            " object with a PCA")
                    Giotto::runGiottoHarmony(g, vars_use = "lens_group",
                        dim_reduction_to_use = "pca", dim_reduction_name = "pca",
                        dimensions_to_use = p$dimensions_to_use, name = "hm_harmony",
                        verbose = FALSE)
                },
                result = function(g, p, before) {
                    m <- GiottoClass::getDimReduction(g, reduction_method = "harmony",
                        name = "hm_harmony", output = "matrix")
                    list(summary = sprintf("%d cells, %d dimensions", nrow(m), ncol(m)))
                },
                code = function(p, up) {
                    col <- Find(Negate(is.null), lapply(up, `[[`, "column_name"))
                    d <- range(p$dimensions_to_use)
                    paste0("g <- runGiottoHarmony(g, vars_use = \"", col,
                        "\", dim_reduction_to_use = \"pca\", dimensions_to_use = ",
                        d[[1L]], ":", d[[2L]], ", name = \"harmony\")")
                }
            ),
            hm_network = list(
                label = "Nearest network", input = "hm_harmony",
                fun = "createNearestNetwork",
                params = list(
                    .param("type", "type", list(.ch("sNN", value = "sNN"),
                        .ch("kNN", value = "kNN")), "sNN"),
                    .pcs("dimensions_to_use", "Harmony dimensions"),
                    .num("k", "k", 30, c(2, 100), min = 2, integer = TRUE)
                ),
                run = function(g, p) Giotto::createNearestNetwork(g, type = p$type,
                    dim_reduction_to_use = "harmony", dim_reduction_name = "hm_harmony",
                    dimensions_to_use = p$dimensions_to_use, k = p$k,
                    name = paste0("hm_", p$type), verbose = FALSE),
                result = function(g, p, before) list(summary = sprintf("%s network, k = %d",
                    p$type, p$k)),
                code = function(p, up) {
                    d <- range(p$dimensions_to_use)
                    paste0("g <- createNearestNetwork(g, type = \"", p$type,
                        "\", dim_reduction_to_use = \"harmony\", dim_reduction_name = ",
                        "\"harmony\", dimensions_to_use = ", d[[1L]], ":", d[[2L]],
                        ", k = ", p$k, ", name = \"", p$type, ".harmony\")")
                }
            ),
            hm_leiden = list(
                label = "Leiden clusters", input = "hm_network",
                fun = "doLeidenCluster",
                params = list(
                    .num("resolution", "resolution", 1, c(0.01, 5), min = 0.001, log = TRUE),
                    .num("n_iterations", "iterations", 20, c(1, 200), min = 1, integer = TRUE)
                ),
                run = function(g, p) Giotto::doLeidenCluster(g,
                    nn_network_to_use = p$up$hm_network$type,
                    network_name = paste0("hm_", p$up$hm_network$type),
                    resolution = p$resolution, n_iterations = p$n_iterations,
                    name = "hm_leiden"),
                result = function(g, p, before) {
                    cm <- as.data.frame(GiottoClass::pDataDT(g))
                    cl <- as.character(cm$hm_leiden)
                    lv <- as.character(sort(unique(as.integer(cl))))
                    tab <- as.data.frame(table(cluster = factor(cl, levels = lv),
                        batch = as.character(cm$lens_group)), stringsAsFactors = FALSE)
                    names(tab)[names(tab) == "Freq"] <- "cells"
                    tot <- stats::ave(tab$cells, tab$cluster, FUN = sum)
                    tab$share <- ifelse(tot > 0, tab$cells / tot, 0)
                    overall <- table(as.character(cm$lens_group)) / nrow(cm)
                    tab$overall_share <- as.numeric(overall[tab$batch])
                    sh <- tapply(tab$share, tab$cluster, max)
                    list(meta = data.frame(cell_ID = as.character(cm$cell_ID),
                            hm_leiden = factor(cl, levels = lv)),
                        mix = tab,
                        summary = sprintf("%d clusters, %d with one batch over 90%%",
                            length(lv), sum(sh > 0.9)))
                },
                view = function(res, p) {
                    mix <- res$mix
                    list(panels = list(list(id = "hm_mix", title = "Batches per cluster",
                            spec = .hm_mix_spec(mix))),
                        tables = list(.analysis_table(mix, id = "hm_mix_table",
                            title = "Batches per Harmony cluster", sort = "cells",
                            note = "share: fraction of the cluster's cells in the batch")))
                },
                code = function(p, up) paste0("g <- doLeidenCluster(g, nn_network_to_use = \"",
                    up$hm_network$type, "\", network_name = \"", up$hm_network$type,
                    ".harmony\", resolution = ", .num_str(p$resolution), ", n_iterations = ",
                    p$n_iterations, ", name = \"harmony_leiden\")")
            ),
            hm_umap = list(
                label = "UMAP", input = "hm_harmony",
                fun = "runUMAP",
                params = list(
                    .pcs("dimensions_to_use", "Harmony dimensions"),
                    .num("n_neighbors", "neighbors", "auto", c(2, 100), min = 2,
                        integer = TRUE, auto = TRUE),
                    .num("min_dist", "min dist", 0.05, c(0, 1), step = 0.01),
                    .num("spread", "spread", 1, c(0.1, 5), min = 0.01, step = 0.1)
                ),
                run = function(g, p) Giotto::runUMAP(g, dim_reduction_to_use = "harmony",
                    dim_reduction_name = "hm_harmony", dimensions_to_use = p$dimensions_to_use,
                    n_neighbors = p$n_neighbors, min_dist = p$min_dist, spread = p$spread,
                    name = "hm_umap", n_threads = .lens_threads(), verbose = FALSE),
                result = function(g, p, before) {
                    m <- GiottoClass::getDimReduction(g, reduction_method = "umap",
                        name = "hm_umap", output = "matrix")
                    cm <- as.data.frame(GiottoClass::pDataDT(g))
                    list(meta = data.frame(cell_ID = rownames(m), hm_umap_1 = m[, 1L],
                            hm_umap_2 = m[, 2L]),
                        points = data.frame(umap_1 = m[, 1L], umap_2 = m[, 2L],
                            batch = as.character(cm$lens_group[match(rownames(m),
                                cm$cell_ID)])),
                        summary = sprintf("%d cells", nrow(m)))
                },
                view = function(res, p) list(panels = list(list(id = "hm_umap",
                    title = "Harmony UMAP by batch", spec = .hm_umap_spec(res$points)))),
                code = function(p, up) {
                    d <- range(p$dimensions_to_use)
                    paste0("g <- runUMAP(g, dim_reduction_to_use = \"harmony\", ",
                        "dim_reduction_name = \"harmony\", dimensions_to_use = ", d[[1L]], ":",
                        d[[2L]], if (!is.null(p$n_neighbors))
                            paste0(", n_neighbors = ", p$n_neighbors),
                        ", min_dist = ", .num_str(p$min_dist), ", spread = ",
                        .num_str(p$spread), ", name = \"umap.harmony\")\n",
                        "plotUMAP(g, dim_reduction_name = \"umap.harmony\", ",
                        "cell_color = \"harmony_leiden\")")
                }
            )
        )
    )
}

# Stacked bars: share of each batch in each Harmony cluster
.hm_mix_spec <- function(d) list(
    `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
    title = "batch share per cluster", width = "container", height = "container",
    data = list(values = d),
    mark = list(type = "bar", tooltip = TRUE),
    encoding = list(
        x = list(field = "cluster", type = "nominal", sort = as.list(unique(d$cluster)),
            title = "Harmony cluster"),
        y = list(field = "share", type = "quantitative", stack = "normalize",
            title = "share of cells"),
        color = list(field = "batch", type = "nominal", title = "batch"),
        tooltip = list(
            list(field = "cluster", type = "nominal"),
            list(field = "batch", type = "nominal"),
            list(field = "cells", type = "quantitative"),
            list(field = "share", type = "quantitative", format = ".2f"),
            list(field = "overall_share", type = "quantitative", format = ".2f",
                title = "share in all cells")))
)

# UMAP points colored by batch
.hm_umap_spec <- function(d) list(
    `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
    title = "UMAP on Harmony dimensions", width = "container", height = "container",
    data = list(values = d),
    mark = list(type = "circle", size = 6, opacity = 0.6),
    encoding = list(
        x = list(field = "umap_1", type = "quantitative", title = "UMAP 1"),
        y = list(field = "umap_2", type = "quantitative", title = "UMAP 2"),
        color = list(field = "batch", type = "nominal", title = "batch"))
)
