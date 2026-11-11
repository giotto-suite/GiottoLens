# ── Cell type enrichment ─────────────────────────────────────────────────────

.analysis_entry_enrichment <- function() list(
    id = "enrichment", label = "Cell type enrichment", order = 100, auto = FALSE,
    brief = "Scores each cell for the marker genes of each cell type (PAGE or hypergeometric).",
    description = paste(
        "Scores every cell for each cell type of the marker list with PAGE (z-score of the",
        "markers' fold change against all genes) or a hypergeometric test (overlap of the",
        "markers with the cell's top expressed genes, as -log10 p-value). Higher scores mean",
        "the cell expresses more of the type's markers; en_best is the type with the highest",
        "score. The table gives the mean score of each type in each Leiden cluster."),
    inputs = c("normalized expression (object or Preprocessing tab)",
        "a marker gene list: launch_lens_analysis(cell_markers =)",
        "optional: leiden_clus for the cluster table"),
    outputs = c("en_<type> scores and en_best (cell metadata)",
        "marker genes found in the panel (table)",
        "mean score per type and Leiden cluster (heatmap and table)"),
    steps = list(
        en_source = .step_source(),
        en_markers = list(
            label = "Marker genes", input = "en_source", markers = TRUE,
            fun = "makeSignMatrixPAGE",
            params = list(),
            run = function(g, p) g,
            result = function(g, p, before) {
                mk <- p$cell_markers
                if (!length(mk)) return(list(summary = "no marker list",
                    stop_below = paste("no marker list: launch_lens_analysis(g, cell_markers =)",
                        "or viewer$analysis$cell_markers()")))
                feats <- GiottoClass::featIDs(g)
                genes <- data.frame(type = rep(names(mk), lengths(mk)),
                    gene = as.character(unlist(mk, use.names = FALSE)))
                genes$in_panel <- genes$gene %in% feats
                n_in <- tapply(genes$in_panel, factor(genes$type, levels = names(mk)), sum)
                list(genes = genes,
                    summary = sprintf("%d of %d marker genes in the panel, %d of %d types with any",
                        sum(genes$in_panel), nrow(genes), sum(n_in > 0), length(mk)),
                    stop_below = if (!any(genes$in_panel)) "no marker gene is in the panel")
            },
            view = function(res, p) {
                if (is.null(res$genes)) return(list())
                list(tables = list(.analysis_table(res$genes, id = "en_genes",
                    title = "Marker genes", feat = "gene", sort = "in_panel",
                    note = "in_panel: the gene is a feature of the object")))
            },
            code = function(p, up) paste0("sign <- makeSignMatrixPAGE(",
                "sign_names = names(cell_markers), sign_list = cell_markers)")
        ),
        en_enrich = list(
            label = "Enrichment", input = "en_markers", markers = TRUE,
            fun = "runPAGEEnrich",
            params = list(
                .param("method", "method", list(.ch("PAGE", value = "PAGE"),
                    .ch("hypergeometric", value = "hypergeometric")), "PAGE"),
                .num("min_overlap_genes", "min overlap genes (PAGE)", 5, c(0, 20),
                    min = 0, integer = TRUE),
                .num("top_percentage", "top % expressed (hypergeometric)", 5, c(1, 50),
                    min = 0.1, max = 100, step = 0.5),
                .param("reverse_log_scale", "reverse log scale",
                    list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE"),
                .param("output_enrichment", "output", list(.ch("original", value = "original"),
                    .ch("zscore", value = "zscore")), "original")
            ),
            run = function(g, p) {
                feats <- GiottoClass::featIDs(g)
                mk <- lapply(p$cell_markers, intersect, feats)
                if (p$method == "PAGE") {
                    mk <- mk[lengths(mk) > p$min_overlap_genes]
                    if (!length(mk)) stop("no cell type has more than ", p$min_overlap_genes,
                        " of its marker genes in the panel (min overlap genes)")
                } else {
                    mk <- mk[lengths(mk) > 0L]
                }
                sm <- Giotto::makeSignMatrixPAGE(sign_names = names(mk), sign_list = mk)
                if (p$method == "PAGE") {
                    Giotto::runPAGEEnrich(g, sign_matrix = sm, expression_values = .lens_values(p),
                        min_overlap_genes = p$min_overlap_genes,
                        reverse_log_scale = p$reverse_log_scale,
                        output_enrichment = p$output_enrichment, name = "en_scores",
                        verbose = FALSE)
                } else {
                    Giotto::runHyperGeometricEnrich(g, sign_matrix = sm,
                        expression_values = .lens_values(p), top_percentage = p$top_percentage,
                        reverse_log_scale = p$reverse_log_scale,
                        output_enrichment = p$output_enrichment, name = "en_scores")
                }
            },
            result = function(g, p, before) {
                e <- as.data.frame(GiottoClass::getSpatialEnrichment(g, name = "en_scores",
                    output = "data.table"))
                types <- setdiff(names(e), "cell_ID")
                m <- as.matrix(e[types])
                best <- types[max.col(m, ties.method = "first")]
                if (p$method != "PAGE") best[apply(m, 1L, max) <= 0] <- NA_character_
                cols <- paste0("en_", gsub("[^A-Za-z0-9_]+", "_", types))
                meta <- data.frame(cell_ID = as.character(e$cell_ID), m, check.names = FALSE)
                names(meta) <- c("cell_ID", cols)
                meta$en_best <- best
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                clus <- NULL
                if ("leiden_clus" %in% names(cm)) {
                    cl <- as.character(cm$leiden_clus[match(e$cell_ID, cm$cell_ID)])
                    lv <- unique(cl[!is.na(cl)])
                    num <- suppressWarnings(as.numeric(lv))
                    lv <- if (!anyNA(num)) lv[order(num)] else sort(lv)
                    clus <- do.call(rbind, lapply(lv, function(k) {
                        rows <- !is.na(cl) & cl == k
                        means <- colMeans(m[rows, , drop = FALSE])
                        data.frame(cluster = k, type = types, mean_score = unname(means),
                            n = sum(rows), top = types == types[which.max(means)])
                    }))
                }
                missing <- setdiff(names(p$cell_markers), types)
                list(meta = meta, clusters = clus,
                    summary = paste0(length(types), " of ", length(p$cell_markers),
                        " cell types scored (", p$method, ")",
                        if (length(missing)) paste0("; too few panel genes: ",
                            paste(missing, collapse = ", "))))
            },
            view = function(res, p) {
                d <- res$clusters
                if (is.null(d)) return(list())
                wide <- stats::reshape(d[c("cluster", "n", "type", "mean_score")],
                    idvar = c("cluster", "n"), timevar = "type", direction = "wide")
                names(wide) <- sub("^mean_score\\.", "", names(wide))
                wide$top_type <- d$type[d$top][match(wide$cluster, d$cluster[d$top])]
                wide <- wide[c("cluster", "n", "top_type",
                    setdiff(names(wide), c("cluster", "n", "top_type")))]
                list(panels = list(list(id = "en_clusters", title = "Enrichment per cluster",
                        spec = .en_cluster_spec(d))),
                    tables = list(.analysis_table(wide, id = "en_cluster_table",
                        title = "Mean enrichment score per Leiden cluster",
                        note = "top_type: type with the highest mean score")))
            },
            code = function(p, up) {
                if (p$method == "PAGE")
                    paste0("g <- runPAGEEnrich(g, sign_matrix = sign, min_overlap_genes = ",
                        p$min_overlap_genes, ", reverse_log_scale = ", p$reverse_log_scale,
                        ", output_enrichment = \"", p$output_enrichment,
                        "\", name = \"PAGE\")")
                else
                    paste0("g <- runHyperGeometricEnrich(g, sign_matrix = sign, ",
                        "top_percentage = ", .num_str(p$top_percentage),
                        ", reverse_log_scale = ", p$reverse_log_scale,
                        ", output_enrichment = \"", p$output_enrichment,
                        "\", name = \"hypergeometric\")")
            }
        )
    )
)

# Heatmap: mean score of each type in each Leiden cluster
.en_cluster_spec <- function(d) list(
    `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
    title = "mean enrichment score", width = "container", height = "container",
    data = list(values = d),
    mark = list(type = "rect", tooltip = TRUE),
    encoding = list(
        x = list(field = "cluster", type = "nominal", sort = as.list(unique(d$cluster)),
            title = "leiden_clus"),
        y = list(field = "type", type = "nominal", title = NULL),
        color = list(field = "mean_score", type = "quantitative", title = "mean score",
            scale = list(scheme = "viridis")),
        tooltip = list(
            list(field = "cluster", type = "nominal"),
            list(field = "type", type = "nominal"),
            list(field = "mean_score", type = "quantitative", format = ".2f",
                title = "mean score"),
            list(field = "n", type = "quantitative", title = "cells")))
)
