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
        "The number of modules is the one with the highest mean silhouette width,",
        "unless set. The heatmap shows the correlation of the genes, with a box around each",
        "module; click a module in the heatmap to color the cells by its score, drag a box",
        "to score the genes of its columns and rows as one set (cm_meta_1, cm_meta_2, ...),",
        "or click a gene in the module table to color the cells by its expression."),
    inputs = c("normalized expression (object or Preprocessing tab)", "spatial locations"),
    outputs = c("module of each gene (table)",
        "module scores per cell as cm_module_<k> (cell metadata)",
        "correlation of the genes, grouped by module (heatmap)"),
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
                    integer = TRUE),
                .advanced(.param("bin_method", "high/low split", list(
                    .ch("kmeans", value = "kmeans"), .ch("rank", value = "rank")), "kmeans")),
                .advanced(.num("percentage_rank", "top % expressed (rank)", 30, c(1, 100),
                    min = 1, max = 100, step = 1)),
                .advanced(.param("null", "null", list(
                    .ch("permutation", value = "permutation"),
                    .ch("covariate", value = "covariate")), "permutation")),
                .advanced(.text_param("covariate", "covariate", default = "libsize",
                    placeholder = "libsize or a cell metadata column")),
                .advanced(.num("n_groups", "covariate groups", 10, c(2, 50), min = 2,
                    integer = TRUE)),
                .advanced(.param("weighted", "use link weights", list(
                    .ch(FALSE, "no"), .ch(TRUE, "yes")), "FALSE")),
                .advanced(.param("adjust_method", "p-value adjustment", lapply(
                    c("fdr", "BH", "BY", "holm", "hochberg", "hommel", "bonferroni", "none"),
                    function(m) .ch(m, value = m)), "fdr"))
            ),
            run = function(g, p) {
                a <- list(bin_method = p$bin_method, null = p$null,
                    weighted = p$null == "permutation" && isTRUE(p$weighted),
                    adjust_method = p$adjust_method)
                if (p$bin_method == "rank") a$percentage_rank <- p$percentage_rank
                if (p$null == "covariate") {
                    cv <- trimws(p$covariate %||% "")
                    a$covariate <- if (nzchar(cv)) cv else "libsize"
                    a$n_groups <- p$n_groups
                }
                do.call(Giotto::spatialAutoCor, c(list(g, method = "binspect",
                    expression_values = .lens_values(p), spatial_network_name = .lens_net(p)),
                    a))
            },
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
                vals <- .values_of(p, up)
                a <- .sg_autocor_args(p, moran = FALSE, binspect = TRUE)
                a$bin_method <- NULL
                paste0("g <- spatialAutoCor(g, method = \"binspect\", bin_method = ",
                    deparse(p$bin_method %||% "kmeans"), ", ",
                    "expression_values = \"", vals, "\", spatial_network_name = ", .code_value(.network_of(p, up)), "",
                    .sg_changed_args(a, .sg_autocor_defaults()), ")")
            }
        ),
        cm_modules = list(
            label = "Co-expression modules", input = "cm_genes",
            fun = "spatialCoexpression",
            params = list(
                utils::modifyList(.num("n_modules", "modules", "auto", c(2, 30), min = 2,
                    max = 100, integer = TRUE, auto = TRUE), list(own_help = TRUE)),
                .num("k_max", "most modules scored", 15, c(3, 40), min = 3, max = 100,
                    integer = TRUE),
                .num("smoothing", "neighbor weight", "auto", c(0, 1), min = 0, max = 1,
                    auto = TRUE, step = 0.05),
                .param("cor_method", "correlation", list(.ch("pearson", value = "pearson"),
                    .ch("spearman", value = "spearman")), "pearson"),
                .param("score_stat", "module score", list(.ch("mean", value = "mean"),
                    .ch("zmean", value = "zmean")), "mean"),
                .advanced(.num("hops", "neighbor hops", 1, c(1, 5), min = 1, max = 20,
                    integer = TRUE)),
                .advanced(.param("weighted", "use link weights", list(
                    .ch(FALSE, "no"), .ch(TRUE, "yes")), "FALSE")),
                .advanced(.param("cluster_method", "clustering linkage", lapply(
                    c("ward.D", "ward.D2", "complete", "average", "single", "mcquitty", "median",
                        "centroid"), function(m) .ch(m, value = m)), "ward.D"))
            ),
            run = function(g, p) {
                sel <- p$up$cm_genes
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                fm <- fm[order(-fm$binspect.z, fm$feat_ID), , drop = FALSE]
                feats <- utils::head(fm$feat_ID[!is.na(fm$binspect.padj) &
                    fm$binspect.padj < sel$padj], sel$n)
                cx <- Giotto::spatialCoexpression(g, expression_values = .lens_values(p),
                    spatial_network_name = .lens_net(p), feats = feats,
                    smoothing = p$smoothing, weighted = isTRUE(p$weighted),
                    hops = p$hops %||% 1L, cor_method = p$cor_method, n_modules = 2L,
                    cluster_method = p$cluster_method %||% "ward.D", return_gobject = FALSE)
                hc <- cx$hclust
                r <- cx$cor[hc$labels, hc$labels, drop = FALSE]
                r[is.na(r)] <- 0
                n <- length(hc$labels)
                ks <- seq.int(2L, max(2L, min(p$k_max, n - 1L)))
                d <- 1 - r
                sil <- vapply(seq_along(ks), function(i) {
                    .lens_progress(i - 1L, length(ks), "module counts scored")
                    .lens_silhouette(d, stats::cutree(hc, k = ks[[i]]))
                }, 1)
                .lens_progress(length(ks), length(ks), "module counts scored")
                k <- if (is.null(p$n_modules)) ks[[which.max(sil)]] else min(p$n_modules, n)
                modules <- stats::cutree(hc, k = k)
                module_cor <- vapply(seq_along(modules), function(i) {
                    same <- setdiff(which(modules == modules[[i]]), i)
                    if (length(same)) mean(r[i, same]) else NA_real_
                }, 1)
                keep <- names(modules)
                if (length(keep) > 120L) {
                    quota <- pmax(1L, floor(120 * table(modules) / length(modules)))
                    keep <- unlist(lapply(names(quota), function(m) {
                        i <- which(modules == as.integer(m))
                        names(modules)[i][utils::head(order(-module_cor[i]), quota[[m]])]
                    }))
                }
                heat <- data.frame(gene_a = rep(keep, times = length(keep)),
                    gene_b = rep(keep, each = length(keep)),
                    cor = as.vector(r[keep, keep, drop = FALSE]),
                    module = unname(modules[rep(keep, times = length(keep))]))
                .lens_keep(list(k = k, auto = is.null(p$n_modules), ks = ks, silhouette = sil,
                    order = hc$labels[hc$order], cor = heat))
                meta <- data.table::data.table(feat_ID = as.character(GiottoClass::featIDs(g)))
                meta$cm_module <- unname(modules[meta$feat_ID])
                meta$cm_module_cor <- module_cor[match(meta$feat_ID, names(modules))]
                g <- GiottoClass::addFeatMetadata(g, new_metadata = meta, by_column = TRUE,
                    column_feat_ID = "feat_ID")
                GiottoClass::createMetafeats(g, expression_values = .lens_values(p),
                    feat_clusters = modules, stat = p$score_stat, name = "cm_module",
                    verbose = FALSE)
            },
            result = function(g, p, before) {
                kept <- .lens_kept()
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
                summ <- do.call(rbind, lapply(mods, function(k) {
                    s <- genes[genes$module == as.integer(k), , drop = FALSE]
                    data.frame(module = as.integer(k), genes = nrow(s),
                        mean_module_cor = mean(s$module_cor),
                        top_genes = paste(utils::head(s$gene, 5L), collapse = ", "))
                }))
                how <- if (isTRUE(kept$auto))
                    sprintf("; %d by silhouette (%.2f), from %d to %d scored", kept$k,
                        max(kept$silhouette), min(kept$ks), max(kept$ks))
                    else if (kept$k %in% kept$ks)
                        sprintf("; silhouette %.2f", kept$silhouette[kept$ks == kept$k])
                    else ""
                list(meta = meta, genes = genes, modules = summ, heat = kept$cor,
                    order = intersect(kept$order, unique(kept$cor$gene_a)),
                    k_scores = data.frame(k = kept$ks, silhouette = kept$silhouette,
                        used = kept$ks == length(mods)),
                    summary = sprintf("%d genes in %d modules%s", nrow(genes), length(mods),
                        how))
            },
            pick = function(value, res, p) {
                k <- unlist(value$k)
                m <- unlist(value$module)
                x <- as.numeric(unlist(value$range$x0))
                y <- as.numeric(unlist(value$range$y0))
                if (length(k)) list(set = list(n_modules = as.integer(k[[1L]])))
                else if (length(m)) list(color = paste0("cm_module_", sub("^M", "", m[[1L]])))
                else if (length(x) == 2L || length(y) == 2L) {
                    genes <- intersect(res$order, unique(res$heat$gene_a))
                    mid <- seq_along(genes) - 0.5
                    inside <- function(r) length(r) == 2L && all(is.finite(r))
                    hit <- rep(FALSE, length(genes))
                    if (inside(x)) hit <- hit | (mid >= min(x) & mid <= max(x))
                    if (inside(y)) hit <- hit | (mid >= min(y) & mid <= max(y))
                    list(genes = genes[hit])
                }
            },
            view = function(res, p) {
                panels <- list(list(id = "cm_heatmap", title = "Co-expression modules",
                    spec = .cm_heatmap_spec(res$heat, res$order)))
                if (!is.null(res$k_scores))
                    panels <- c(panels, list(list(id = "cm_k", title = "Modules: number",
                        spec = .k_scores_spec(res$k_scores, "modules"))))
                list(panels = panels,
                    tables = list(
                        .analysis_table(res$genes, id = "cm_module_genes", title = "Module genes",
                            feat = "gene",
                            note = "click a gene to color the cells by its expression"),
                        .analysis_table(res$modules, id = "cm_module_summary",
                            title = "Modules")))
            },
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                vals <- .values_of(p, up)
                sel <- up$cm_genes
                adv <- .sg_changed_args(.sg_fill(p, .cm_module_defaults())[c("weighted",
                    "hops", "cluster_method")], .cm_module_defaults())
                call <- function(k) paste0("g <- spatialCoexpression(g, expression_values = ",
                    arg(vals), ", spatial_network_name = ", .code_value(.network_of(p, up)), ", ",
                    "feats = head(fm$feat_ID, ", arg(sel$n), ")",
                    if (!is.null(p$smoothing)) paste0(", smoothing = ", arg(p$smoothing)),
                    ", cor_method = ", arg(p$cor_method), ", n_modules = ", k,
                    ", score_stat = ", arg(p$score_stat), adv, ", name = \"cm_module\")\n")
                pick <- if (is.null(p$n_modules)) paste0(
                    "cx <- spatialCoexpression(g, expression_values = ", arg(vals),
                    ", spatial_network_name = ", .code_value(.network_of(p, up)), ", feats = head(fm$feat_ID, ",
                    arg(sel$n), ")",
                    if (!is.null(p$smoothing)) paste0(", smoothing = ", arg(p$smoothing)),
                    ", cor_method = ", arg(p$cor_method), adv, ", return_gobject = FALSE)\n",
                    "r <- cx$cor[cx$hclust$labels, cx$hclust$labels]\n",
                    "r[is.na(r)] <- 0\n",
                    "ks <- 2:min(", arg(p$k_max), ", nrow(r) - 1)\n",
                    "silhouette <- sapply(ks, function(k) mean(cluster::silhouette(",
                    "cutree(cx$hclust, k), as.dist(1 - r))[, \"sil_width\"]))\n",
                    "n_modules <- ks[which.max(silhouette)]\n") else ""
                paste0("fm <- fDataDT(g)[binspect.padj < ", arg(sel$padj),
                    "][order(-binspect.z)]\n", pick,
                    call(if (is.null(p$n_modules)) "n_modules" else arg(p$n_modules)),
                    "spatCellPlot(g, spat_enr_names = \"cm_module\", ",
                    "cell_annotation_values = as.character(1:",
                    if (is.null(p$n_modules)) "n_modules" else arg(p$n_modules), "))")
            }
        )
    )
)

.cm_module_defaults <- function() list(weighted = FALSE, hops = 1, cluster_method = "ward.D")

# Correlation of the genes in `order`, placed by position, with a strip of
# their modules on top and a box around each module's block; all layers read
# the top-level data, split by `row`. A click (param `pick`) gives the module,
# a dragged box (param `range`) the positions of the genes of its columns and
# rows.
.cm_heatmap_spec <- function(d, order) {
    genes <- intersect(order, unique(d$gene_a))
    n <- length(genes)
    pos <- stats::setNames(seq_len(n) - 1L, genes)
    mod <- paste0("M", d$module[match(genes, d$gene_a)])
    names(mod) <- genes
    mods <- unique(mod)
    cells <- data.frame(row = "cor", x0 = pos[d$gene_a], x1 = pos[d$gene_a] + 1L,
        y0 = pos[d$gene_b], y1 = pos[d$gene_b] + 1L, gene_a = d$gene_a, gene_b = d$gene_b,
        cor = d$cor, module = mod[d$gene_a])
    strip <- data.frame(row = "module", x0 = pos, x1 = pos + 1L, y0 = -1.4, y1 = -0.4,
        gene_a = genes, gene_b = NA_character_, cor = NA_real_, module = mod)
    boxes <- do.call(rbind, lapply(mods, function(m) {
        at <- pos[mod == m]
        data.frame(row = "box", x0 = min(at), x1 = max(at) + 1L, y0 = min(at),
            y1 = max(at) + 1L, gene_a = NA_character_, gene_b = NA_character_, cor = NA_real_,
            module = m)
    }))
    rows <- rbind(cells, strip, boxes)
    rownames(rows) <- NULL
    only <- function(k) list(list(filter = paste0("datum.row == '", k, "'")))
    pal <- list(domain = as.list(mods), scheme = "tableau20")
    xy <- list(
        x = list(field = "x0", type = "quantitative", axis = NULL,
            scale = list(domain = list(0, n), nice = FALSE, zero = FALSE)),
        x2 = list(field = "x1"),
        y = list(field = "y0", type = "quantitative", axis = NULL,
            scale = list(domain = list(-1.4, n), nice = FALSE, zero = FALSE, reverse = TRUE)),
        y2 = list(field = "y1"))
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = list(text = sprintf("correlation of %d genes in %d modules%s", n, length(mods),
                if (n >= 120L) " (top genes per module)" else ""),
            subtitle = paste("click a module to color the cells by its score; drag a box to",
                "score the genes of its columns and rows as one set")),
        width = "container", height = "container",
        data = list(values = rows),
        resolve = list(scale = list(color = "independent")),
        layer = list(
            list(transform = only("cor"),
                params = list(
                    list(name = "pick", select = list(type = "point", fields = list("module"),
                        on = "click", clear = "dblclick")),
                    list(name = "range", select = list(type = "interval",
                        encodings = list("x", "y"), translate = FALSE, zoom = FALSE,
                        clear = "dblclick"))),
                mark = list(type = "rect", tooltip = TRUE, cursor = "pointer"),
                encoding = c(xy, list(
                    color = list(field = "cor", type = "quantitative", title = "correlation",
                        scale = list(scheme = "redblue", reverse = TRUE,
                            domain = list(-1, 1)),
                        legend = list(orient = "bottom", direction = "horizontal")),
                    tooltip = list(
                        list(field = "module", type = "nominal"),
                        list(field = "gene_a", type = "nominal", title = "gene"),
                        list(field = "gene_b", type = "nominal", title = "gene"),
                        list(field = "cor", type = "quantitative", format = ".2f",
                            title = "correlation"))))),
            list(transform = only("module"),
                mark = list(type = "rect", tooltip = TRUE),
                encoding = c(xy, list(
                    color = list(field = "module", type = "nominal", title = "module",
                        scale = pal,
                        legend = list(orient = "bottom", direction = "horizontal")),
                    tooltip = list(list(field = "module", type = "nominal"),
                        list(field = "gene_a", type = "nominal", title = "gene"))))),
            list(transform = only("box"),
                mark = list(type = "rect", filled = FALSE, strokeWidth = 2),
                encoding = c(xy, list(
                    stroke = list(field = "module", type = "nominal", scale = pal,
                        legend = NULL)))))
    )
}

# Mean silhouette width by number of clusters: the highest marked in amber,
# the number in use filled; a click on a point (param `pick`) uses that number
.k_scores_spec <- function(d, what) {
    d$best <- d$silhouette == max(d$silhouette)
    if (is.null(d$used)) d$used <- d$best
    d$status <- ifelse(d$used, "in use", ifelse(d$best, "highest score", ""))
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = list(text = paste("mean silhouette width by number of", what),
            subtitle = paste("click a point to use that number of", what)),
        width = "container", height = "container",
        data = list(values = d),
        encoding = list(
            x = list(field = "k", type = "quantitative", title = what,
                axis = list(tickMinStep = 1)),
            y = list(field = "silhouette", type = "quantitative",
                title = "mean silhouette width")),
        layer = list(
            list(mark = list(type = "line")),
            list(transform = list(list(filter = "datum.best")),
                mark = list(type = "point", size = 260, shape = "circle", filled = FALSE,
                    color = "#f59e0b", strokeWidth = 2)),
            list(transform = list(list(filter = "datum.used")),
                mark = list(type = "point", size = 110, shape = "circle", filled = TRUE,
                    color = "#e5e7eb")),
            list(params = list(list(name = "pick",
                    select = list(type = "point", fields = list("k"), on = "click",
                        clear = "dblclick"))),
                mark = list(type = "point", size = 60, filled = TRUE, cursor = "pointer",
                    tooltip = TRUE),
                encoding = list(
                    tooltip = list(list(field = "k", type = "quantitative", title = what),
                        list(field = "silhouette", type = "quantitative", format = ".3f"),
                        list(field = "status", type = "nominal", title = " ")))))
    )
}

.analysis_help_coexpression <- function() list(
    cm_genes = list(
        padj = paste0(
            "Adjusted p-value cutoff for the spatial pattern test (binSpect). Only genes below it ",
            "are grouped into modules. For example, 0.05 keeps genes with a clear spatial ",
            "pattern."),
        n = paste0(
            "Maximum number of genes grouped into modules, taken in order of significance. More ",
            "genes give larger modules and take longer."),
        bin_method = paste0(
            "How each gene is split into high and low cells for the spatial pattern test. ",
            "kmeans: two groups by k-means on the gene's values. rank: the top percentage of ",
            "cells by expression (see top % expressed)."),
        percentage_rank = paste0(
            "For the rank split. The percentage of cells with the highest expression of a gene ",
            "that count as high. For example, 30 counts the top 30% of cells. Lower values look ",
            "only at the strongest expression."),
        null = paste0(
            "The random placement the test compares with. permutation: high cells placed at ",
            "random over the tissue. covariate: cells switch on at the rate of their covariate ",
            "group, so a pattern that only follows the covariate (for example library size or ",
            "cell type) does not count as spatial. With the covariate null, links are not ",
            "weighted."),
        covariate = paste0(
            "For the covariate null. libsize: the total raw counts of each cell. Or the name of ",
            "a cell metadata column, for example cell_type. A numeric column is cut into ",
            "'covariate groups' groups; a categorical one is used as is."),
        n_groups = paste0(
            "For the covariate null with a numeric covariate. Number of groups of equal size the ",
            "cells are split into by the covariate. For example, 10 groups cells by the deciles ",
            "of library size. More groups follow the covariate more closely."),
        weighted = paste0(
            "For the permutation null. Whether the links of the spatial network are weighted by ",
            "their weight column, 1 / (1 + distance), so closer cells count more. no: every link ",
            "counts the same."),
        adjust_method = paste0(
            "How p-values are corrected for testing many genes (see stats::p.adjust). fdr and ",
            "BH: Benjamini-Hochberg false discovery rate; for example, genes with adjusted p ",
            "below 0.05 are expected to include about 5% false positives. BY: a stricter false ",
            "discovery rate. holm, hochberg, hommel and bonferroni control the chance of any ",
            "false positive and give larger adjusted p-values, so fewer genes pass. none: no ",
            "correction.")),
    cm_modules = list(
        n_modules = paste0(
            "Number of modules the genes are split into. A module is a group of genes whose ",
            "spatially smoothed expression rises and falls together. More modules are smaller and ",
            "more specific. auto: every number from 2 to the most modules tried is scored by the ",
            "mean silhouette width of the genes (how much closer each gene is to the genes of ",
            "its own module than to those of the nearest other module, on 1 - correlation), and ",
            "the highest score is used."),
        k_max = paste0(
            "The largest number of modules scored in the silhouette chart, and tried by auto. ",
            "For example, 15 scores 2 to 15 modules. A click on a point of the chart uses that ",
            "number of modules."),
        smoothing = paste0(
            "How much each cell's expression is mixed with its neighbors' before genes are ",
            "correlated, from 0 (no mixing: plain co-expression) to 1 (neighbors only). For ",
            "example, 0.5 gives the cell and its neighbors equal weight. Empty: Giotto's default ",
            "(1 - 1/k, with k the median number of neighbors)."),
        cor_method = paste0(
            "How genes are correlated. pearson: on the values. spearman: on the ranks of the ",
            "values, so a few very high values matter less."),
        score_stat = paste0(
            "How each cell's module score is computed from the module's genes. mean: average of ",
            "their values. zmean: average after each gene is z-scored, so highly expressed genes ",
            "do not dominate."),
        hops = paste0(
            "How far the smoothing reaches, in links of the spatial network. For example, 1 ",
            "averages each cell with its direct neighbors and 2 also with their neighbors. ",
            "Higher values give smoother, broader patterns."),
        weighted = paste0(
            "Whether neighbors are weighted by the weight column of the spatial network, ",
            "1 / (1 + distance), so closer cells count more in the smoothing. no: every neighbor ",
            "counts the same."),
        cluster_method = paste0(
            "How genes are joined into modules in the hierarchical clustering of their ",
            "correlation (see stats::hclust). ward.D and ward.D2: compact modules of similar ",
            "size. complete: a gene joins a module only when it is close to all of its genes. ",
            "average: by the mean distance. single: by the closest gene, which can give one ",
            "large module. mcquitty, median, centroid: other averaging rules."))
)

.analysis_show_coexpression <- function() list(
    cm_genes = list(
        percentage_rank = list(bin_method = "rank"),
        covariate = list(null = "covariate"),
        n_groups = list(null = "covariate"),
        weighted = list(null = "permutation"))
)
