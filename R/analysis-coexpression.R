# ── Spatial co-expression modules ────────────────────────────────────────────

.analysis_entry_coexpression <- function() list(
    id = "coexpression", label = "Spatial co-expression modules", order = 30, auto = FALSE,
    brief = "Groups of spatial genes that rise and fall together across the tissue.",
    description = paste(
        "Finds spatial genes with binSpect (kmeans), averages each cell's expression",
        "with its neighbors' in a spatial network, correlates the genes on the smoothed",
        "values and clusters them into modules.",
        "Each module gets a score per cell, the mean expression of its genes",
        "(metadata columns cm_module_1, cm_module_2, ...).",
        "The heatmap shows the correlation of the module scores across cells; click a",
        "gene in the module table to color the cells by its expression."),
    inputs = c("normalized expression (object or Preprocessing tab)", "spatial locations"),
    outputs = c("module of each gene (table)",
        "module scores per cell as cm_module_<k> (cell metadata)",
        "correlation of the module scores (heatmap)"),
    steps = list(
        cm_source = .step_source(),
        cm_network = .step_network(input = "cm_source"),
        cm_genes = list(
            label = "Spatial genes", input = "cm_network",
            fun = "spatialAutoCor",
            params = list(
                .num("padj", "adj. p below", 0.05, c(1e-10, 0.1), min = 0, max = 1,
                    log = TRUE),
                .num("n", "genes (at most)", 80, c(10, 500), min = 3, max = 2000,
                    integer = TRUE)
            ),
            run = function(g, p) Giotto::spatialAutoCor(g, method = "binspect",
                bin_method = "kmeans", expression_values = .lens_values(p),
                spatial_network_name = "lens_spatial"),
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                fm <- fm[order(-fm$binspect.z, fm$feat_ID), , drop = FALSE]
                pass <- fm$feat_ID[!is.na(fm$binspect.padj) & fm$binspect.padj < p$padj]
                used <- utils::head(pass, p$n)
                list(used = used,
                    summary = sprintf("%d of %d genes with adj. p < %s; %d used",
                        length(pass), nrow(fm), format(p$padj), length(used)),
                    stop_below = if (length(used) < 3L)
                        "fewer than 3 spatial genes pass the threshold")
            },
            code = function(p, up) {
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                paste0("g <- spatialAutoCor(g, method = \"binspect\", bin_method = \"kmeans\", ",
                    "expression_values = \"", vals, "\", spatial_network_name = \"lens_spatial\")")
            }
        ),
        cm_modules = list(
            label = "Co-expression modules", input = "cm_genes",
            fun = "spatialCoexpression",
            params = list(
                .num("n_modules", "modules", 10, c(2, 30), min = 2, max = 100, integer = TRUE),
                .num("smoothing", "neighbor weight", "auto", c(0, 1), min = 0, max = 1,
                    auto = TRUE, step = 0.05),
                .param("cor_method", "correlation", list(.ch("pearson", value = "pearson"),
                    .ch("spearman", value = "spearman")), "pearson"),
                .param("score_stat", "module score", list(.ch("mean", value = "mean"),
                    .ch("zmean", value = "zmean")), "mean")
            ),
            run = function(g, p) {
                sel <- p$up$cm_genes
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                fm <- fm[order(-fm$binspect.z, fm$feat_ID), , drop = FALSE]
                feats <- utils::head(fm$feat_ID[!is.na(fm$binspect.padj) &
                    fm$binspect.padj < sel$padj], sel$n)
                Giotto::spatialCoexpression(g, expression_values = .lens_values(p),
                    spatial_network_name = "lens_spatial", feats = feats,
                    smoothing = p$smoothing, cor_method = p$cor_method,
                    n_modules = p$n_modules, score_stat = p$score_stat, name = "cm_module")
            },
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                fm <- fm[!is.na(fm$cm_module), , drop = FALSE]
                genes <- data.frame(gene = as.character(fm$feat_ID),
                    module = as.integer(fm$cm_module), module_cor = fm$cm_module_cor,
                    binspect_z = fm$binspect.z)
                genes <- genes[order(genes$module, -genes$module_cor), , drop = FALSE]
                rownames(genes) <- NULL
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g, name = "cm_module",
                    output = "data.table"))
                mods <- as.character(sort(as.integer(setdiff(names(e), "cell_ID"))))
                sc <- as.matrix(e[mods])
                colnames(sc) <- paste0("cm_module_", mods)
                meta <- data.frame(cell_ID = as.character(e$cell_ID), sc, check.names = FALSE)
                cm <- suppressWarnings(stats::cor(sc))
                cm[!is.finite(cm)] <- 0
                lab <- paste0("M", mods)
                ord <- if (length(mods) > 2L) lab[stats::hclust(stats::as.dist(1 - cm))$order]
                    else lab
                heat <- data.frame(module_a = rep(lab, times = length(lab)),
                    module_b = rep(lab, each = length(lab)), cor = as.vector(cm))
                summ <- do.call(rbind, lapply(mods, function(k) {
                    s <- genes[genes$module == as.integer(k), , drop = FALSE]
                    data.frame(module = as.integer(k), genes = nrow(s),
                        mean_module_cor = mean(s$module_cor),
                        top_genes = paste(utils::head(s$gene, 5L), collapse = ", "))
                }))
                list(meta = meta, genes = genes, modules = summ, heat = heat, order = ord,
                    summary = sprintf("%d genes in %d modules", nrow(genes), length(mods)))
            },
            view = function(res, p) list(
                panels = list(list(id = "cm_heatmap", title = "Co-expression modules",
                    spec = .cm_heatmap_spec(res$heat, res$order))),
                tables = list(
                    .analysis_table(res$genes, id = "cm_module_genes", title = "Module genes",
                        feat = "gene", note = "click a gene to color the cells by its expression"),
                    .analysis_table(res$modules, id = "cm_module_summary", title = "Modules"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                sel <- up$cm_genes
                paste0("fm <- fDataDT(g)[binspect.padj < ", arg(sel$padj),
                    "][order(-binspect.z)]\n",
                    "g <- spatialCoexpression(g, expression_values = ", arg(vals),
                    ", spatial_network_name = \"lens_spatial\", feats = head(fm$feat_ID, ",
                    arg(sel$n), ")",
                    if (!is.null(p$smoothing)) paste0(", smoothing = ", arg(p$smoothing)),
                    ", cor_method = ", arg(p$cor_method), ", n_modules = ", arg(p$n_modules),
                    ", score_stat = ", arg(p$score_stat), ", name = \"cm_module\")\n",
                    "spatCellPlot(g, spat_enr_names = \"cm_module\", ",
                    "cell_annotation_values = as.character(1:", arg(p$n_modules), "))")
            }
        )
    )
)

# Correlation of the module scores across cells, in `order`
.cm_heatmap_spec <- function(d, order) list(
    `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
    title = "correlation of module scores", width = "container", height = "container",
    data = list(values = d),
    mark = list(type = "rect", tooltip = TRUE),
    encoding = list(
        x = list(field = "module_a", type = "nominal", sort = as.list(order), title = NULL),
        y = list(field = "module_b", type = "nominal", sort = as.list(order), title = NULL),
        color = list(field = "cor", type = "quantitative", title = "correlation",
            scale = list(scheme = "redblue", reverse = TRUE, domain = list(-1, 1))),
        tooltip = list(
            list(field = "module_a", type = "nominal", title = "module"),
            list(field = "module_b", type = "nominal", title = "module"),
            list(field = "cor", type = "quantitative", format = ".2f", title = "correlation")))
)
