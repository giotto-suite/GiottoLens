# ── Cluster tree ─────────────────────────────────────────────────────────────

.ct_groups <- function() {
    s <- .step_groups(label = "Clusters", input = "ct_source")
    s$params[[1L]]$label <- "cluster column"
    s$params[[1L]]$default <- "leiden_clus"
    s
}

.ct_methods <- function() c(list(.ch("scran", value = "scran"), .ch("gini", value = "gini")),
    if (requireNamespace("MAST", quietly = TRUE)) list(.ch("mast", value = "mast")))

.analysis_entry_cluster_tree <- function() list(
    id = "cluster_tree", label = "Cluster tree", order = 80, auto = FALSE,
    brief = "A tree of the clusters by the correlation of their mean expression.",
    description = paste(
        "Averages expression per cluster, correlates the cluster means and joins",
        "the clusters into a tree by hierarchical clustering of 1 - correlation.",
        "Clusters joined low in the tree have similar expression. The Split markers",
        "step counts the genes that separate the two sides of each split: a split",
        "with few strong markers joins clusters that barely differ."),
    inputs = c("normalized expression (object or Preprocessing tab)",
        "a categorical cluster column"),
    outputs = c("cluster tree (dendrogram) and its splits (table)",
        "markers of each split and their count (dendrogram and tables)"),
    steps = list(
        ct_source = .step_source(),
        ct_groups = .ct_groups(),
        ct_tree = list(
            label = "Cluster tree", input = "ct_groups",
            fun = "calculateClusterTree",
            params = list(
                .param("feats", "features", list(
                    .ch("hvf", "highly variable", value = "hvf"),
                    .ch(NULL, "all", value = "all")), "hvf"),
                .param("cor", "correlation", list(.ch("pearson", value = "pearson"),
                    .ch("spearman", value = "spearman")), "pearson"),
                .param("distance", "linkage", lapply(c("average", "ward.D", "ward.D2",
                    "complete", "single", "mcquitty", "median", "centroid"),
                    function(m) .ch(m, value = m)), "average")
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                feats <- if (identical(p$feats, "hvf") && "hvf" %in% names(fm))
                    fm$feat_ID[fm$hvf == "yes"]
                if (identical(p$feats, "hvf") && !length(feats)) feats <- NULL
                n_types <- length(unique(GiottoClass::pDataDT(g)$lens_group))
                if (n_types < 3L) stop("a tree needs at least three clusters; the column has ",
                    n_types)
                tr <- Giotto::calculateClusterTree(g, expression_values = .lens_values(p),
                    cluster_column = "lens_group", feats = feats, cor = p$cor,
                    distance = p$distance)
                sp <- as.data.frame(tr)
                side <- function(x) vapply(x, function(v) paste(unlist(v), collapse = ", "), "")
                splits <- data.frame(nodeID = as.integer(sp$nodeID), height = sp$node_h,
                    left = side(sp$left), right = side(sp$right),
                    n_left = vapply(sp$left, function(v) length(unlist(v)), 1L),
                    n_right = vapply(sp$right, function(v) length(unlist(v)), 1L))
                list(tree = list(merge = unclass(tr)$merge, height = unclass(tr)$height,
                        order = unclass(tr)$order, labels = as.character(unclass(tr)$labels)),
                    splits = splits,
                    summary = sprintf("%d clusters, %d splits (%s features, %s, %s)",
                        length(tr$labels), nrow(splits),
                        if (is.null(feats)) "all" else length(feats), p$cor, p$distance))
            },
            view = function(res, p) list(
                panels = list(list(id = "ct_dendrogram", title = "Cluster tree",
                    spec = .ct_dendrogram_spec(res$tree, res$splits))),
                tables = list(.analysis_table(res$splits, "ct_splits", "Cluster tree splits",
                    sort = "height"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(v), collapse = "")
                col <- up$ct_groups$column_name
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                paste0(
                    if (identical(p$feats, "hvf"))
                        "feats <- fDataDT(g)[hvf == \"yes\"]$feat_ID\n" else "feats <- NULL\n",
                    "tree <- calculateClusterTree(g, expression_values = ", arg(vals),
                    ", cluster_column = ", arg(col), ", feats = feats, cor = ", arg(p$cor),
                    ", distance = ", arg(p$distance), ")\n",
                    "splits <- as.data.frame(tree)\n",
                    "plot(tree, hang = -1)")
            }
        ),
        ct_markers = list(
            label = "Split markers", input = "ct_tree",
            fun = "findClusterTreeMarkers",
            params = list(
                .param("method", "method", .ct_methods(), "scran"),
                .num("lfc_cut", "strong: min log fold change", 0.25, c(0, 3), step = 0.05),
                .num("fdr_cut", "strong: max FDR", 0.01, c(0, 0.1), max = 1, step = 0.001)
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                tp <- p$up$ct_tree
                fm <- as.data.frame(GiottoClass::fDataDT(g))
                feats <- if (identical(tp$feats, "hvf") && "hvf" %in% names(fm))
                    fm$feat_ID[fm$hvf == "yes"]
                if (identical(tp$feats, "hvf") && !length(feats)) feats <- NULL
                vals <- .lens_values(p)
                tr <- Giotto::calculateClusterTree(g, expression_values = vals,
                    cluster_column = "lens_group", feats = feats, cor = tp$cor,
                    distance = tp$distance)
                nm <- Giotto::findClusterTreeMarkers(g, tree = tr, expression_values = vals,
                    cluster_column = "lens_group", method = p$method, lfc_cut = p$lfc_cut,
                    fdr_cut = p$fdr_cut, verbose = FALSE)
                side <- function(x) vapply(x, function(v) paste(unlist(v), collapse = ", "), "")
                nodes <- as.data.frame(nm$nodes)
                nodes <- data.frame(nodeID = as.integer(nodes$nodeID), height = nodes$node_h, row.names = NULL,
                    left = side(nodes$left), right = side(nodes$right),
                    n_strong = as.integer(nodes$n_strong))
                mk <- as.data.frame(nm$markers)
                names(mk) <- gsub(".", "_", names(mk), fixed = TRUE)
                names(mk)[names(mk) == "feats"] <- "feat"
                mk <- mk[c(intersect(c("nodeID", "side", "feat"), names(mk)),
                    setdiff(names(mk), c("nodeID", "side", "feat")))]
                rownames(mk) <- NULL
                list(tree = list(merge = unclass(tr)$merge, height = unclass(tr)$height,
                        order = unclass(tr)$order, labels = as.character(unclass(tr)$labels)),
                    nodes = nodes, markers = mk,
                    summary = sprintf("%d splits, %d to %d strong markers (%s)", nrow(nodes),
                        min(nodes$n_strong), max(nodes$n_strong), p$method))
            },
            view = function(res, p) list(
                panels = list(list(id = "ct_node_markers", title = "Cluster tree: split markers",
                    spec = .ct_dendrogram_spec(res$tree, res$nodes, color = "n_strong"))),
                tables = list(
                    .analysis_table(res$nodes, "ct_nodes", "Strong markers per split",
                        sort = "n_strong", decreasing = FALSE),
                    .analysis_table(res$markers, "ct_markers", "Split markers", feat = "feat",
                        note = "side: the side of the split the gene marks"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(v), collapse = "")
                col <- up$ct_groups$column_name
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                paste0("nm <- findClusterTreeMarkers(g, tree = tree, expression_values = ",
                    arg(vals), ", cluster_column = ", arg(col), ", method = ", arg(p$method),
                    ", lfc_cut = ", arg(p$lfc_cut), ", fdr_cut = ", arg(p$fdr_cut), ")")
            }
        )
    )
)

# Link, node and leaf coordinates of an hclust tree (`merge`, `height`,
# `order`, `labels`); leaves at x = 1..n in tree order, y = 0
.ct_dendrogram_coords <- function(tree) {
    n <- length(tree$labels)
    merge <- matrix(tree$merge, ncol = 2L)
    pos <- integer(n)
    pos[tree$order] <- seq_len(n)
    nx <- numeric(n - 1L)
    links <- vector("list", n - 1L)
    for (i in seq_len(n - 1L)) {
        a <- merge[i, 1L]; b <- merge[i, 2L]
        xa <- if (a < 0) pos[-a] else nx[a]; ya <- if (a < 0) 0 else tree$height[a]
        xb <- if (b < 0) pos[-b] else nx[b]; yb <- if (b < 0) 0 else tree$height[b]
        h <- tree$height[i]
        nx[i] <- (xa + xb) / 2
        links[[i]] <- data.frame(nodeID = i, x = c(xa, xb, xa), x2 = c(xa, xb, xb),
            y = c(ya, yb, h), y2 = c(h, h, h))
    }
    list(links = do.call(rbind, links),
        nodes = data.frame(nodeID = seq_len(n - 1L), x = nx, y = tree$height),
        leaves = data.frame(label = tree$labels[tree$order], x = seq_len(n), y = 0))
}

# Dendrogram as rule marks; `nodes` adds its columns to the node points, and
# `color` names the node column that colors them
.ct_dendrogram_spec <- function(tree, nodes, color = NULL) {
    co <- .ct_dendrogram_coords(tree)
    pts <- merge(co$nodes, nodes[setdiff(names(nodes), c("x", "y", "height"))],
        by = "nodeID", all.x = TRUE)
    pts$height <- pts$y
    n <- nrow(co$leaves)
    xs <- list(field = "x", type = "quantitative", axis = NULL,
        scale = list(domain = list(0.5, n + 0.5)))
    ys <- list(field = "y", type = "quantitative", title = "height (1 - correlation)")
    tips <- lapply(setdiff(names(pts), c("x", "y")), function(k)
        list(field = k, type = if (is.numeric(pts[[k]])) "quantitative" else "nominal"))
    point_enc <- list(x = xs, y = ys, tooltip = tips)
    point_mark <- list(type = "point", filled = TRUE, size = 30, color = "black",
        tooltip = TRUE)
    if (!is.null(color)) {
        point_enc$color <- list(field = color, type = "quantitative", title = color,
            scale = list(scheme = "viridis"))
        point_mark$color <- NULL
        point_mark$size <- 80
    }
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = "cluster tree", width = "container", height = "container",
        layer = list(
            list(data = list(values = co$links),
                mark = list(type = "rule", color = "gray"),
                encoding = list(x = xs, x2 = list(field = "x2"), y = ys,
                    y2 = list(field = "y2"))),
            list(data = list(values = pts),
                mark = point_mark, encoding = point_enc),
            list(data = list(values = co$leaves),
                mark = list(type = "text", baseline = "top", dy = 4),
                encoding = list(x = xs, y = ys, text = list(field = "label"))))
    )
}
