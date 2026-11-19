# ── Markers between groups ───────────────────────────────────────────────────

# Gini filter parameters of findMarkers() and findMarkers_one_vs_all()
.mg_gini_args <- c("min_expression", "min_detection", "min_expression_gini",
    "min_detection_gini", "detection_threshold", "min_length", "rank_score")

# Methods that use the p-value and log fold change cutoffs
.mg_stat_methods <- function() c("scran", if (requireNamespace("MAST", quietly = TRUE)) "mast")

# R code of the advanced arguments of a step that differ from their default:
# ", arg = value" for each; `args` names parameter ids, or maps parameter ids
# (names) to argument names. A parameter hidden by its `show_if` is left out.
.cl_adv_code <- function(p, analysis, step, args) {
    if (is.null(names(args))) names(args) <- args
    names(args)[!nzchar(names(args))] <- args[!nzchar(names(args))]
    ent <- get(paste0(".analysis_entry_", analysis), envir = environment(.cl_adv_code))()
    pars <- ent$steps[[step]]$params
    sf <- get0(paste0(".analysis_show_", analysis), envir = environment(.cl_adv_code),
        mode = "function")
    show <- if (!is.null(sf)) sf()[[step]] else list()
    out <- character()
    for (id in names(args)) {
        if (!id %in% names(p)) next
        par <- Find(function(q) identical(q$id, id), pars)
        if (is.null(par)) next
        ok <- TRUE
        for (ctrl in names(show[[id]]))
            if (!isTRUE(as.character(p[[ctrl]] %||% "auto") %in% show[[id]][[ctrl]])) ok <- FALSE
        if (!ok) next
        v <- p[[id]]
        if (identical(par$type, "text")) v <- .text_list(v)
        def <- .param_r(par, par$default)
        if (identical(par$type, "text")) def <- .text_list(def)
        if (length(v) == length(def) && all(as.character(v) == as.character(def))) next
        if (is.integer(v)) v <- as.numeric(v)
        out <- c(out, paste0(", ", args[[id]], " = ", paste(deparse(v), collapse = "")))
    }
    paste(out, collapse = "")
}

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
                    integer = TRUE),
                .advanced(.text_param("subset_clusters", "groups compared (each vs all)",
                    placeholder = "two or more, comma-separated; empty: all groups")),
                .advanced(.num("pair_min_feats", "min markers per group (gini, pair)", 4,
                    c(0, 50), integer = TRUE)),
                .advanced(.num("min_expression", "gini: min mean expression", 0.5, c(0, 5),
                    step = 0.1)),
                .advanced(.num("min_detection", "gini: min fraction detected", 0.5, c(0, 1),
                    max = 1, step = 0.01)),
                .advanced(.num("min_expression_gini", "gini: min expression gini", "auto",
                    c(0, 1), step = 0.01, auto = TRUE)),
                .advanced(.num("min_detection_gini", "gini: min detection gini", "auto",
                    c(0, 1), step = 0.01, auto = TRUE)),
                .advanced(.num("detection_threshold", "gini: detection threshold", 0, c(0, 5),
                    step = 0.1)),
                .advanced(.num("min_length", "gini: pad to clusters", 0, c(0, 50),
                    integer = TRUE)),
                .advanced(.num("rank_score", "gini: max cluster rank", "auto", c(1, 20),
                    min = 1, integer = TRUE, auto = TRUE))
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                groups <- sort(unique(as.character(GiottoClass::pDataDT(g)$lens_group)))
                vals <- .lens_values(p)
                if (p$mode == "one_vs_all") {
                    sub <- trimws(strsplit(as.character(p$subset_clusters %||% ""), ",",
                        fixed = TRUE)[[1L]])
                    sub <- sub[nzchar(sub)]
                    bad <- setdiff(sub, groups)
                    if (length(bad)) stop("not a group of the column: ",
                        paste(bad, collapse = ", "), "; groups: ", paste(groups, collapse = ", "))
                    if (length(sub) == 1L) stop("groups compared needs at least two groups")
                    m <- Giotto::findMarkers_one_vs_all(g, expression_values = vals,
                        cluster_column = "lens_group", method = p$method,
                        subset_clusters = if (length(sub)) sub, pval = p$pval,
                        logFC = p$logFC, min_feats = p$min_feats,
                        min_expression = p$min_expression, min_detection = p$min_detection,
                        min_expression_gini = p$min_expression_gini %||% -Inf,
                        min_detection_gini = p$min_detection_gini %||% -Inf,
                        detection_threshold = p$detection_threshold,
                        min_length = p$min_length, rank_score = p$rank_score %||% Inf,
                        verbose = FALSE)
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
                        group_1 = g1, group_2 = g2, group_1_name = n1, group_2_name = n2,
                        min_expression = p$min_expression, min_detection = p$min_detection,
                        min_expression_gini = p$min_expression_gini %||% -Inf,
                        min_detection_gini = p$min_detection_gini %||% -Inf,
                        detection_threshold = p$detection_threshold,
                        min_length = p$min_length, rank_score = p$rank_score %||% Inf,
                        min_feats = p$pair_min_feats)
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
                vals <- .values_of(p, up)
                if (identical(p$mode, "one_vs_all"))
                    return(paste0("markers <- findMarkers_one_vs_all(g, expression_values = ",
                        arg(vals), ", cluster_column = ", arg(col), ", method = ", arg(p$method),
                        ", pval = ", arg(p$pval), ", logFC = ", arg(p$logFC),
                        ", min_feats = ", arg(p$min_feats),
                        .cl_adv_code(p, "markers_groups", "mg_markers", c("subset_clusters",
                            .mg_gini_args)), ")"))
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
                        else "rest"),
                    .cl_adv_code(p, "markers_groups", "mg_markers", c(.mg_gini_args,
                        pair_min_feats = "min_feats")), ")")
            }
        )
    )
)

.analysis_help_markers_groups <- function() list(
    mg_groups = list(
        column = paste0(
            "The cell metadata label used for the groups to compare, for example cell_type or ",
            "leiden_clus. Labels marked (Preprocessing) come from the Preprocessing tab.")),
    mg_markers = list(
        method = paste0(
            "How genes are compared between groups. scran: a statistical test. gini: genes with ",
            "high expression in one group and low expression in the others."),
        mode = paste0(
            "What is compared. each vs all: every group against all other cells. group 1 vs group ",
            "2: the groups named below against each other."),
        group_1 = paste0(
            "For group 1 vs group 2. Values of the label that make up group 1, comma-separated, ",
            "for example 1, 4 or T/NK."),
        group_2 = paste0(
            "For group 1 vs group 2. Values of the label that make up group 2, comma-separated. ",
            "Empty: all cells not in group 1."),
        pval = paste0(
            "For each vs all with scran. Maximum p-value for a gene to be listed as a marker, for example ",
            "0.01."),
        logFC = paste0(
            "For each vs all with scran. Minimum log fold change (higher expression in the group than in all ",
            "other cells) for a gene to be listed as a marker."),
        min_feats = paste0(
            "For each vs all. Minimum number of genes listed for each group, even when fewer pass ",
            "the cutoffs. For example, 10 lists the 10 best-ranked genes of a group when none pass. ",
            "Higher values list more genes per group."),
        subset_clusters = paste0(
            "For each vs all. Groups compared, comma-separated, for example 1, 4, 7 or Myeloid, ",
            "T/NK. Only the cells of these groups are used: each listed group is compared with ",
            "the other listed groups. Needs at least two groups. Empty: all groups."),
        pair_min_feats = paste0(
            "For group 1 vs group 2 with gini. Minimum number of genes listed for each group, even ",
            "when fewer pass the gini cutoffs. For example, 4 lists the 4 best-ranked genes. ",
            "Higher values list more genes."),
        min_expression = paste0(
            "For gini. Minimum mean expression of a gene in a group (normalized values) for it to ",
            "be listed as a marker of that group. For example, 0.5 drops genes whose mean in the ",
            "group is below 0.5. Higher values keep fewer, more highly expressed markers."),
        min_detection = paste0(
            "For gini. Minimum fraction of a group's cells in which a gene is detected (above the ",
            "detection threshold) for it to be listed as a marker of that group. For example, 0.5 ",
            "needs the gene in at least half of the group's cells. Higher values keep fewer, ",
            "more widely expressed markers."),
        min_expression_gini = paste0(
            "For gini. Minimum gini coefficient of a gene's mean expression across groups. The ",
            "coefficient is near 0 when the gene has the same mean in every group and near 1 when ",
            "it is expressed in one group only. For example, 0.3 drops genes spread evenly over ",
            "the groups. Higher values keep fewer, more specific markers. Empty: no cutoff."),
        min_detection_gini = paste0(
            "For gini. Minimum gini coefficient of the fraction of cells detecting a gene across ",
            "groups, from near 0 (detected equally in every group) to near 1 (detected in one ",
            "group only). For example, 0.3 drops genes detected evenly in all groups. Higher ",
            "values keep fewer, more specific markers. Empty: no cutoff."),
        detection_threshold = paste0(
            "For gini. The expression value above which a cell counts as expressing a gene, used ",
            "for the fraction of cells detected. For example, with 0 any expression counts; with ",
            "1 only values above 1. Higher values lower the fractions, so fewer genes pass min ",
            "fraction detected."),
        min_length = paste0(
            "For gini. The number of groups the gini coefficients are computed over: with fewer ",
            "groups, the values are padded with copies of the lowest value. For example, 20 gives ",
            "coefficients that compare between a 5-group and a 12-group column. 0: no padding. ",
            "Higher values raise the coefficients."),
        rank_score = paste0(
            "For gini. A gene is kept as a marker of a group only when that group is within this ",
            "rank, for both mean expression and fraction detected, among all groups (rank 1: the ",
            "highest). For example, 1 keeps a gene only for the group where it is highest. Lower ",
            "values keep fewer markers. Empty: no cutoff."))
)

.analysis_show_markers_groups <- function() list(
    mg_markers = list(
        group_1 = list(mode = "pair"),
        group_2 = list(mode = "pair"),
        pval = list(mode = "one_vs_all", method = .mg_stat_methods()),
        logFC = list(mode = "one_vs_all", method = .mg_stat_methods()),
        min_feats = list(mode = "one_vs_all"),
        subset_clusters = list(mode = "one_vs_all"),
        pair_min_feats = list(mode = "pair", method = "gini"),
        min_expression = list(method = "gini"),
        min_detection = list(method = "gini"),
        min_expression_gini = list(method = "gini"),
        min_detection_gini = list(method = "gini"),
        detection_threshold = list(method = "gini"),
        min_length = list(method = "gini"),
        rank_score = list(method = "gini"))
)
