# ── Markers between groups ───────────────────────────────────────────────────

.analysis_entry_markers_groups <- function() list(
    id = "markers_groups", label = "Markers between groups", order = 60, auto = FALSE,
    brief = "Genes that differ between the groups of a categorical column.",
    description = paste(
        "Finds marker genes for the groups of a cell metadata column: each group",
        "against all other cells, or group 1 against group 2. Group 1 and group 2",
        "take comma-separated group names; an empty group 2 means all other groups.",
        "The table lists the markers of each group with their rank and scores;",
        "click a row to color the cells by that gene."),
    inputs = c("normalized expression (object or Preprocessing tab)",
        "a categorical cell metadata column"),
    outputs = c("marker genes per group (table)"),
    steps = list(
        mg_source = .step_source(),
        mg_groups = .step_groups(label = "Groups", input = "mg_source"),
        mg_markers = list(
            label = "Markers", input = "mg_groups",
            fun = "findMarkers",
            params = list(
                .param("method", "method", c(list(.ch("scran", value = "scran"),
                    .ch("gini", value = "gini")),
                    if (requireNamespace("MAST", quietly = TRUE))
                        list(.ch("mast", value = "mast"))), "scran"),
                .param("mode", "compare", list(
                    .ch("one_vs_all", "each group vs all others", value = "one_vs_all"),
                    .ch("pair", "group 1 vs group 2", value = "pair")), "one_vs_all"),
                .text_param("group_1", "group 1", placeholder = "group names, comma-separated"),
                .text_param("group_2", "group 2", placeholder = "empty: all other groups"),
                .num("pval", "max p-value (each vs all)", 0.01, c(0, 0.1), max = 1,
                    step = 0.001),
                .num("logFC", "min log fold change (each vs all)", 0.5, c(0, 5), step = 0.1),
                .num("min_feats", "min markers per group (each vs all)", 10, c(0, 50),
                    integer = TRUE)
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                groups <- sort(unique(as.character(GiottoClass::pDataDT(g)$lens_group)))
                vals <- .lens_values(p)
                if (p$mode == "one_vs_all") {
                    m <- Giotto::findMarkers_one_vs_all(g, expression_values = vals,
                        cluster_column = "lens_group", method = p$method, pval = p$pval,
                        logFC = p$logFC, min_feats = p$min_feats, verbose = FALSE)
                    what <- "each group vs all others"
                } else {
                    split_names <- function(x) {
                        x <- trimws(strsplit(as.character(x %||% ""), ",", fixed = TRUE)[[1L]])
                        x[nzchar(x)]
                    }
                    g1 <- split_names(p$group_1)
                    g2 <- split_names(p$group_2)
                    if (!length(g1)) stop("group 1 needs one or more of: ",
                        paste(groups, collapse = ", "))
                    bad <- setdiff(c(g1, g2), groups)
                    if (length(bad)) stop("not a group of the column: ",
                        paste(bad, collapse = ", "), "; groups: ", paste(groups, collapse = ", "))
                    both <- intersect(g1, g2)
                    if (length(both)) stop("in group 1 and group 2: ", paste(both, collapse = ", "))
                    n2 <- if (length(g2)) paste(g2, collapse = ", ") else "rest"
                    if (!length(g2)) g2 <- setdiff(groups, g1)
                    if (!length(g2)) stop("group 2 is empty: group 1 holds every group")
                    n1 <- paste(g1, collapse = ", ")
                    m <- Giotto::findMarkers(g, expression_values = vals,
                        cluster_column = "lens_group", method = p$method,
                        group_1 = g1, group_2 = g2, group_1_name = n1, group_2_name = n2)
                    if (!is.data.frame(m)) m <- m[[1L]]
                    what <- paste(n1, "vs", n2)
                }
                m <- as.data.frame(m)
                names(m) <- gsub(".", "_", names(m), fixed = TRUE)
                names(m)[names(m) == "feats"] <- "feat"
                names(m)[names(m) == "cluster"] <- "group"
                if ("summary_logFC" %in% names(m)) {
                    m <- m[!startsWith(names(m), "logFC")]
                    names(m)[names(m) == "summary_logFC"] <- "logFC"
                }
                if ("comb_score" %in% names(m)) m <- m[is.finite(m$comb_score), , drop = FALSE]
                rank <- intersect(c("Top", "comb_rank", "ranking"), names(m))
                if (nrow(m)) {
                    m$group <- as.character(m$group)
                    m <- m[order(m$group, if (length(rank)) m[[rank[[1L]]]] else
                        seq_len(nrow(m))), , drop = FALSE]
                }
                m <- m[c(intersect(c("group", "feat"), names(m)),
                    setdiff(names(m), c("group", "feat")))]
                rownames(m) <- NULL
                list(markers = m, what = what,
                    summary = sprintf("%d markers in %d groups (%s, %s)", nrow(m),
                        length(unique(m$group)), p$method, what))
            },
            view = function(res, p) list(tables = list(.analysis_table(res$markers,
                "mg_markers", "Markers between groups", feat = "feat",
                note = paste0(p$method, ", ", res$what)))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                col <- up$mg_groups$column_name
                vals <- if (isTRUE(up$normalize$scale)) "scaled" else "normalized"
                if (identical(p$mode, "one_vs_all"))
                    return(paste0("markers <- findMarkers_one_vs_all(g, expression_values = ",
                        arg(vals), ", cluster_column = ", arg(col), ", method = ", arg(p$method),
                        ", pval = ", arg(p$pval), ", logFC = ", arg(p$logFC),
                        ", min_feats = ", arg(p$min_feats), ")"))
                split_names <- function(x) {
                    x <- trimws(strsplit(as.character(x %||% ""), ",", fixed = TRUE)[[1L]])
                    x[nzchar(x)]
                }
                g1 <- split_names(p$group_1)
                g2 <- split_names(p$group_2)
                g2_code <- if (length(g2)) arg(g2) else
                    paste0("setdiff(unique(pDataDT(g)[[", arg(col), "]]), ", arg(g1), ")")
                paste0("markers <- findMarkers(g, expression_values = ", arg(vals),
                    ", cluster_column = ", arg(col), ", method = ", arg(p$method),
                    ", group_1 = ", arg(g1), ", group_2 = ", g2_code,
                    ", group_1_name = ", arg(paste(g1, collapse = ", ")),
                    ", group_2_name = ", arg(if (length(g2)) paste(g2, collapse = ", ")
                        else "rest"), ")")
            }
        )
    )
)
