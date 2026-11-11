# ── Subclustering ────────────────────────────────────────────────────────────

.sc_source <- function() {
    s <- .step_source()
    s$result <- function(g, p, before) {
        ex <- as.data.frame(GiottoClass::list_expression(g))
        cm <- GiottoClass::pDataDT(g)
        has <- "normalized" %in% ex$name
        has_cl <- "leiden_clus" %in% names(cm)
        list(summary = sprintf("%d cells, %d features, %s (%s)",
                length(GiottoClass::spatIDs(g)), length(GiottoClass::featIDs(g)),
                if (has_cl) sprintf("%d Leiden clusters",
                    length(unique(stats::na.omit(cm$leiden_clus)))) else "no leiden_clus",
                if (p$from == "preprocess") "Preprocessing tab" else "loaded object"),
            stop_below = if (!has) paste("no normalized expression: run the Preprocessing",
                "tab or load an object with normalized values")
            else if (!has_cl) "no leiden_clus column: run the Preprocessing tab")
    }
    s
}

.analysis_entry_subcluster <- function() list(
    id = "subcluster", label = "Subclustering", order = 70, auto = FALSE,
    brief = "Splits chosen Leiden clusters into subclusters.",
    description = paste(
        "Takes the cells of each chosen Leiden cluster, finds their highly variable",
        "features, runs PCA, builds a nearest network and clusters them with Leiden.",
        "Clusters left out keep one subcluster. Labels read",
        "<cluster>.<subcluster> in the cell metadata column sc_subcluster."),
    inputs = c("normalized expression and leiden_clus (object or Preprocessing tab)"),
    outputs = c("sc_subcluster (cell metadata)", "cells per subcluster (bar chart and table)"),
    steps = list(
        sc_source = .sc_source(),
        sc_subcluster = list(
            label = "Leiden subclusters", input = "sc_source",
            fun = "doLeidenSubCluster",
            params = list(
                .text_param("selected_clusters", "clusters",
                    placeholder = "comma-separated; empty: all clusters"),
                .num("resolution", "resolution", 0.5, c(0.01, 5), min = 0.001, log = TRUE),
                .num("k_neighbors", "k neighbors", 10, c(2, 100), min = 2, integer = TRUE),
                .num("n_iterations", "iterations", 20, c(1, 200), min = 1, integer = TRUE),
                .param("reverse_log_scale", "HVF: reverse log scale",
                    list(.ch(TRUE, "yes", disk = FALSE), .ch(FALSE, "no")), "TRUE"),
                .num("difference_in_cov", "HVF: difference in cov", 1, c(0, 2), step = 0.05),
                .num("hvf_min_perc_cells", "HVF: min % cells", 5, c(0, 50), max = 100,
                    step = 0.5),
                .num("hvf_mean_expr_det", "HVF: min mean expression", 1, c(0, 5), step = 0.1),
                .num("min_nr_of_hvf", "min HVF (else all features)", 5, c(0, 50),
                    integer = TRUE),
                .param("scale_unit", "PCA: scale features",
                    list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE"),
                .num("ncp", "PCA: components", 20, c(2, 100), min = 2, integer = TRUE),
                .pcs("dimensions_to_use", "PCs for network", c(1L, 20L))
            ),
            run = function(g, p) {
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                cl <- as.character(cm$leiden_clus)
                clusters <- unique(cl[!is.na(cl)])
                clusters <- clusters[order(suppressWarnings(as.numeric(clusters)), clusters)]
                sel <- trimws(strsplit(as.character(p$selected_clusters %||% ""), ",",
                    fixed = TRUE)[[1L]])
                sel <- sel[nzchar(sel)]
                if (!length(sel)) sel <- clusters
                bad <- setdiff(sel, clusters)
                if (length(bad)) stop("not a cluster of leiden_clus: ", paste(bad, collapse = ", "),
                    "; clusters: ", paste(clusters, collapse = ", "))
                out <- list()
                for (k in clusters) {
                    ids <- cm$cell_ID[!is.na(cl) & cl == k]
                    if (!k %in% sel) {
                        out[[k]] <- data.frame(cell_ID = ids, parent = k, sub = "1")
                        next
                    }
                    if (length(ids) <= p$k_neighbors) stop(sprintf(
                        "cluster %s has %d cells; it needs more than k neighbors (%d)",
                        k, length(ids), p$k_neighbors))
                    tg <- GiottoClass::subsetGiotto(g, cell_ids = ids, verbose = FALSE)
                    tg <- Giotto::addStatistics(tg, verbose = FALSE)
                    tg <- Giotto::calculateHVF(tg, expression_values = "normalized",
                        reverse_log_scale = p$reverse_log_scale,
                        difference_in_cov = p$difference_in_cov,
                        show_plot = FALSE, return_plot = FALSE, save_plot = FALSE,
                        verbose = FALSE)
                    fm <- as.data.frame(GiottoClass::fDataDT(tg))
                    use <- fm$feat_ID[fm$hvf == "yes" & fm$perc_cells >= p$hvf_min_perc_cells &
                        fm$mean_expr_det >= p$hvf_mean_expr_det]
                    if (length(use) <= p$min_nr_of_hvf) use <- fm$feat_ID
                    ncp <- min(p$ncp, length(ids) - 1L, length(use))
                    tg <- Giotto::runPCA(tg, expression_values = "normalized",
                        feats_to_use = use, scale_unit = p$scale_unit, ncp = ncp,
                        verbose = FALSE)
                    tg <- Giotto::createNearestNetwork(tg,
                        dimensions_to_use = p$dimensions_to_use[p$dimensions_to_use <= ncp],
                        k = p$k_neighbors, verbose = FALSE)
                    tc <- Giotto::doLeidenCluster(tg, resolution = p$resolution,
                        n_iterations = p$n_iterations, name = "tempclus",
                        return_gobject = FALSE)
                    out[[k]] <- data.frame(cell_ID = as.character(tc$cell_ID), parent = k,
                        sub = as.character(tc$tempclus))
                }
                tog <- do.call(rbind, unname(out))
                GiottoClass::addCellMetadata(g, new_metadata = data.table::data.table(
                    cell_ID = tog$cell_ID, sc_subcluster = paste0(tog$parent, ".", tog$sub)),
                    by_column = TRUE, column_cell_ID = "cell_ID")
            },
            result = function(g, p, before) {
                cm <- as.data.frame(GiottoClass::pDataDT(g))
                sc <- as.character(cm$sc_subcluster)
                parent <- sub("\\.[^.]*$", "", sc)
                tab <- as.data.frame(table(subcluster = sc), stringsAsFactors = FALSE)
                names(tab)[names(tab) == "Freq"] <- "cells"
                tab$cluster <- sub("\\.[^.]*$", "", tab$subcluster)
                tab$sub <- sub("^.*\\.", "", tab$subcluster)
                tab <- tab[order(suppressWarnings(as.numeric(tab$cluster)), tab$cluster,
                    suppressWarnings(as.numeric(tab$sub)), tab$sub), ]
                tab$share <- round(tab$cells / stats::ave(tab$cells, tab$cluster, FUN = sum), 3)
                tab <- tab[c("cluster", "subcluster", "cells", "share")]
                rownames(tab) <- NULL
                n_split <- sum(tapply(tab$subcluster, tab$cluster, length) > 1L)
                list(meta = data.frame(cell_ID = as.character(cm$cell_ID),
                        sc_subcluster = factor(sc, levels = tab$subcluster)),
                    sizes = tab,
                    summary = sprintf("%d subclusters; %d of %d clusters split",
                        nrow(tab), n_split, length(unique(parent))))
            },
            view = function(res, p) list(
                panels = list(list(id = "sc_sizes", title = "Subclusters",
                    spec = .sc_sizes_spec(res$sizes))),
                tables = list(.analysis_table(res$sizes, "sc_sizes", "Subclusters"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v) && length(v) == 1L)
                    as.numeric(v) else v), collapse = "")
                sel <- trimws(strsplit(as.character(p$selected_clusters %||% ""), ",",
                    fixed = TRUE)[[1L]])
                sel <- sel[nzchar(sel)]
                dims <- p$dimensions_to_use
                paste0(
                    "cm <- pDataDT(g)\n",
                    "clusters <- as.character(sort(unique(cm$leiden_clus)))\n",
                    "selected <- ", if (length(sel)) arg(sel) else "clusters", "\n",
                    "sub <- lapply(clusters, function(k) {\n",
                    "    ids <- cm[leiden_clus == k]$cell_ID\n",
                    "    if (!k %in% selected) return(data.table(cell_ID = ids, parent = k, tempclus = 1))\n",
                    "    tg <- subsetGiotto(g, cell_ids = ids)\n",
                    "    tg <- addStatistics(tg)\n",
                    "    tg <- calculateHVF(tg, expression_values = \"normalized\", reverse_log_scale = ",
                    arg(p$reverse_log_scale), ", difference_in_cov = ", arg(p$difference_in_cov), ")\n",
                    "    fm <- fDataDT(tg)\n",
                    "    use <- fm[hvf == \"yes\" & perc_cells >= ", arg(p$hvf_min_perc_cells),
                    " & mean_expr_det >= ", arg(p$hvf_mean_expr_det), "]$feat_ID\n",
                    "    if (length(use) <= ", arg(p$min_nr_of_hvf), ") use <- fm$feat_ID\n",
                    "    tg <- runPCA(tg, expression_values = \"normalized\", feats_to_use = use, scale_unit = ",
                    arg(p$scale_unit), ", ncp = min(", arg(p$ncp), ", length(ids) - 1, length(use)))\n",
                    "    npc <- ncol(getDimReduction(tg, output = \"matrix\"))\n",
                    "    tg <- createNearestNetwork(tg, dimensions_to_use = intersect(", dims[[1L]], ":",
                    dims[[length(dims)]], ", seq_len(npc)), k = ", arg(p$k_neighbors), ")\n",
                    "    tc <- doLeidenCluster(tg, resolution = ", arg(p$resolution),
                    ", n_iterations = ", arg(p$n_iterations),
                    ", name = \"tempclus\", return_gobject = FALSE)\n",
                    "    tc[, parent := k]\n",
                    "})\n",
                    "sub <- rbindlist(sub, use.names = TRUE)\n",
                    "g <- addCellMetadata(g, new_metadata = sub[, .(cell_ID, sc_subcluster = ",
                    "paste0(parent, \".\", tempclus))], by_column = TRUE, column_cell_ID = \"cell_ID\")")
            }
        )
    )
)

# Cells per subcluster, stacked by cluster
.sc_sizes_spec <- function(d) {
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "cells per subcluster", width = "container", height = "container",
        data = list(values = d),
        mark = list(type = "bar", tooltip = TRUE),
        encoding = list(
            x = list(field = "cluster", type = "nominal", sort = as.list(unique(d$cluster)),
                title = "Leiden cluster"),
            y = list(field = "cells", type = "quantitative", title = "cells"),
            color = list(field = "subcluster", type = "nominal", sort = as.list(d$subcluster),
                title = "subcluster"),
            tooltip = list(list(field = "subcluster", type = "nominal"),
                list(field = "cells", type = "quantitative"),
                list(field = "share", type = "quantitative", format = ".1%")))
    )
}
