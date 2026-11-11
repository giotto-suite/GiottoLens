# ── Spatial genes ────────────────────────────────────────────────────────────

.analysis_entry_spatial_genes <- function() list(
    id = "spatial_genes", label = "Spatial genes", order = 20, auto = FALSE,
    brief = "Which genes are expressed in spatial patterns across the tissue.",
    description = paste(
        "Links each cell to its neighbors in a spatial network and tests every gene",
        "for spatial clustering of its expression with binSpect (kmeans or rank",
        "binarization), silhouetteRank, Moran's I or Geary's C; Moran's I and Geary's C",
        "give one score per gene for the whole tissue.",
        "Genes are ranked by score (z-score for binSpect, Moran and Geary); a small",
        "adjusted p-value means the pattern is unlikely under random placement of the cells.",
        "Click a gene to color the cells by its expression."),
    inputs = c("normalized expression (object or Preprocessing tab)",
        "spatial locations", "optional: highly variable features (hvf column)"),
    outputs = c("ranked table of genes with scores and adjusted p-values",
        "bar chart of the top genes"),
    steps = list(
        sg_source = .step_source(),
        sg_network = .step_network(input = "sg_source"),
        sg_genes = list(
            label = "Spatial genes", input = "sg_network",
            fun = "binSpect",
            params = list(
                .param("method", "method", list(
                    .ch("binspect_kmeans", "binSpect kmeans", value = "binspect_kmeans"),
                    .ch("binspect_rank", "binSpect rank", value = "binspect_rank"),
                    .ch("silhouette", "silhouetteRank", value = "silhouette"),
                    .ch("moran", "Moran's I", value = "moran"),
                    .ch("geary", "Geary's C", value = "geary")), "binspect_kmeans"),
                .param("feats", "genes", list(
                    .ch("all", "all", value = "all"),
                    .ch("hvf", "highly variable", value = "hvf")), "all"),
                .num("percentage_rank", "top % expressed (binSpect rank)", 30, c(1, 100),
                    min = 1, max = 100, step = 1)
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                feats <- NULL
                note <- ""
                if (identical(p$feats, "hvf")) {
                    if ("hvf" %in% names(fm)) feats <- as.character(fm$feat_ID[fm$hvf == "yes"])
                    else note <- "; no hvf column, all genes tested"
                }
                vals <- .lens_values(p)
                m <- p$method
                r <- if (m %in% c("binspect_kmeans", "binspect_rank")) {
                    Giotto::binSpect(g, bin_method = sub("binspect_", "", m, fixed = TRUE),
                        expression_values = vals, subset_feats = feats,
                        spatial_network_name = "lens_spatial",
                        percentage_rank = p$percentage_rank, verbose = FALSE)
                } else if (m %in% c("moran", "geary")) {
                    Giotto::spatialAutoCor(g, method = m, expression_values = vals,
                        spatial_network_name = "lens_spatial", feats = feats,
                        return_gobject = FALSE)
                } else {
                    Giotto::silhouetteRank(g, expression_values = vals, subset_genes = feats)
                }
                r <- as.data.frame(r)
                gene <- as.character(if ("feats" %in% names(r)) r$feats else r$genes)
                score <- if ("z" %in% names(r)) r$z else if ("score" %in% names(r)) r$score
                    else r$scores
                tab <- data.frame(gene = gene, score = score)
                if ("p.value" %in% names(r)) tab$p_value <- r$p.value
                if ("adj.p.value" %in% names(r)) tab$adj_p_value <- r$adj.p.value
                for (k in intersect(c("statistic", "expected", "variance", "estimate",
                        "n_on", "odds_ratio"), names(r)))
                    tab[[k]] <- r[[k]]
                tab <- tab[order(-tab$score, tab$gene), , drop = FALSE]
                tab <- cbind(rank = seq_len(nrow(tab)), tab)
                rownames(tab) <- NULL
                label <- c(binspect_kmeans = "binSpect kmeans", binspect_rank = "binSpect rank",
                    silhouette = "silhouetteRank", moran = "Moran's I",
                    geary = "Geary's C")[[m]]
                list(genes = tab, method = label,
                    summary = if ("adj_p_value" %in% names(tab))
                        sprintf("%d of %d genes with adj. p < 0.05 (%s)%s",
                            sum(tab$adj_p_value < 0.05, na.rm = TRUE), nrow(tab), label, note)
                    else sprintf("%d genes ranked (%s)%s", nrow(tab), label, note))
            },
            view = function(res, p) list(
                panels = list(list(id = "sg_top", title = "Spatial genes",
                    spec = .sg_top_spec(res$genes, res$method))),
                tables = list(.analysis_table(res$genes, id = "sg_gene_table",
                    title = paste("Spatial genes:", res$method), feat = "gene",
                    sort = "score", note = "click a gene to color the cells by its expression"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                hvf <- identical(p$feats, "hvf")
                pre <- if (hvf) "feats <- fDataDT(g)[hvf == \"yes\", feat_ID]\n" else ""
                m <- p$method
                call <- if (m %in% c("binspect_kmeans", "binspect_rank")) {
                    paste0("sg <- binSpect(g, bin_method = ",
                        arg(sub("binspect_", "", m, fixed = TRUE)),
                        ", expression_values = ", arg(vals),
                        if (hvf) ", subset_feats = feats",
                        ", spatial_network_name = \"lens_spatial\"",
                        if (m == "binspect_rank")
                            paste0(", percentage_rank = ", arg(p$percentage_rank)), ")")
                } else if (m %in% c("moran", "geary")) {
                    paste0("sg <- spatialAutoCor(g, method = ", arg(m),
                        ", expression_values = ", arg(vals),
                        ", spatial_network_name = \"lens_spatial\"",
                        if (hvf) ", feats = feats", ", return_gobject = FALSE)")
                } else {
                    paste0("sg <- silhouetteRank(g, expression_values = ", arg(vals),
                        if (hvf) ", subset_genes = feats", ")")
                }
                paste0(pre, call)
            }
        )
    )
)

# Scores of the top `n` genes as bars
.sg_top_spec <- function(d, method, n = 30L) {
    d <- utils::head(d[is.finite(d$score), c("rank", "gene", "score"), drop = FALSE], n)
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = paste("top genes,", method), width = "container", height = "container",
        data = list(values = d),
        mark = list(type = "bar", tooltip = TRUE),
        encoding = list(
            y = list(field = "gene", type = "nominal", sort = as.list(d$gene), title = NULL),
            x = list(field = "score", type = "quantitative", title = "score"),
            tooltip = list(
                list(field = "rank", type = "quantitative"),
                list(field = "gene", type = "nominal"),
                list(field = "score", type = "quantitative", format = ".3g")))
    )
}
