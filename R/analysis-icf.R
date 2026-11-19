# ── Interaction-changed genes ────────────────────────────────────────────────

.analysis_entry_icf <- function() list(
    id = "icf", label = "Interaction-changed genes", order = 50, auto = FALSE,
    brief = "Genes whose expression in a cell type changes next to another cell type.",
    description = paste(
        "For each pair of cell types, compares the normalized expression of each gene",
        "in cells of the first type that are linked to the second type in a spatial",
        "network (sel) with cells of the first type that are not (other). The table",
        "lists genes that pass the log2 fold-change, adjusted p-value and cell count",
        "thresholds; click a gene to color the cells by its expression."),
    inputs = c("normalized expression (Preprocessing tab or object)",
        "a categorical cell type column", "spatial locations"),
    outputs = c("interaction-changed genes per cell type and neighbor type (table)"),
    steps = list(
        icf_source = .step_source(),
        icf_groups = .step_groups(input = "icf_source"),
        icf_network = .step_network(input = "icf_groups"),
        icf_test = list(
            label = "Interaction-changed genes", input = "icf_network",
            fun = "findInteractionChangedFeats",
            params = list(
                .param("diff_test", "test", list(
                    .ch("permutation", value = "permutation"),
                    .ch("limma", value = "limma", disk = FALSE),
                    .ch("t.test", value = "t.test", disk = FALSE),
                    .ch("wilcox", value = "wilcox", disk = FALSE)), "permutation"),
                .num("nr_permutations", "permutations", 1000, c(10, 10000), min = 1,
                    integer = TRUE, log = TRUE),
                .param("adjust_method", "p-value adjustment", lapply(c("fdr", "bonferroni",
                    "BH", "holm", "hochberg", "hommel", "BY", "none"),
                    function(m) .ch(m, value = m)), "fdr"),
                .view_param(.num("min_log2fc", "min |log2 fold-change|", 0.2, c(0, 3),
                    step = 0.05)),
                .view_param(.num("max_padj", "max adjusted p-value", 0.1, c(0, 1), max = 1,
                    step = 0.01)),
                .view_param(.num("min_cells", "min cells", 4, c(1, 100), min = 1,
                    integer = TRUE)),
                .advanced(.text_param("selected_feats", "genes to test",
                    placeholder = "all genes")),
                .advanced(.num("minimum_unique_cells", "min cells of the cell type", 1,
                    c(1, 50), min = 1, integer = TRUE)),
                .advanced(.num("minimum_unique_int_cells", "min cells of the neighbor type", 1,
                    c(1, 50), min = 1, integer = TRUE)),
                .advanced(.param("mean_method", "mean", list(
                    .ch("arithmic", "arithmetic", value = "arithmic"),
                    .ch("geometric", value = "geometric", disk = FALSE)), "arithmic")),
                .advanced(.num("offset", "offset", 0.1, c(0.001, 1), min = 0, step = 0.01,
                    log = TRUE)),
                .advanced(.param("exclude_selected_cells_from_test",
                    "exclude neighbor-linked cells from other",
                    list(.ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE")),
                .advanced(.num("seed_number", "seed", 1234, c(1, 10000), min = 0,
                    integer = TRUE))
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                pairs <- unique(Giotto::annotateSpatialNetwork(g,
                    spatial_network_name = .lens_net(p),
                    cluster_column = "lens_group")$unified_int)
                feats <- trimws(unlist(strsplit(as.character(p$selected_feats %||% ""), ",",
                    fixed = TRUE)))
                feats <- feats[nzchar(feats)]
                icf <- .lens_count_calls(
                    Giotto::findInteractionChangedFeats(g, expression_values = .lens_values(p),
                        selected_feats = if (length(feats)) feats,
                        cluster_column = "lens_group", spatial_network_name = .lens_net(p),
                        minimum_unique_cells = p$minimum_unique_cells %||% 1,
                        minimum_unique_int_cells = p$minimum_unique_int_cells %||% 1,
                        diff_test = p$diff_test, mean_method = p$mean_method %||% "arithmic",
                        offset = p$offset %||% 0.1, nr_permutations = p$nr_permutations,
                        adjust_method = p$adjust_method,
                        exclude_selected_cells_from_test =
                            p$exclude_selected_cells_from_test %||% TRUE,
                        do_parallel = FALSE, seed_number = p$seed_number %||% 1234),
                    "Giotto", ".findCellProximityFeats_per_interaction", length(pairs),
                    "cell type pairs")
                s <- as.data.frame(icf$ICFscores)
                list(scores = data.frame(gene = as.character(s$feats),
                        cell_type = as.character(s$cell_type),
                        neighbor_type = as.character(s$int_cell_type),
                        nr_select = s$nr_select, int_nr_select = s$int_nr_select,
                        nr_other = s$nr_other, sel = s$sel, other = s$other,
                        log2fc = s$log2fc, p_adj = s$p.adj),
                    summary = sprintf("%d gene x cell type pairs tested", nrow(s)))
            },
            view = function(res, p) {
                s <- res$scores
                keep <- s$nr_select >= p$min_cells & s$int_nr_select >= p$min_cells &
                    abs(s$log2fc) >= p$min_log2fc & !is.na(s$p_adj) & s$p_adj <= p$max_padj
                tab <- s[keep, setdiff(names(s), "int_nr_select"), drop = FALSE]
                pairs <- unique(paste(tab$cell_type, tab$neighbor_type, sep = "--"))
                list(tables = list(.analysis_table(tab,
                    id = "icf_genes", title = sprintf("Interaction-changed genes: %d in %d pairs",
                        nrow(tab), length(pairs)), feat = "gene",
                    sort = "log2fc",
                    note = paste("sel: mean expression in cells of the cell type linked to the",
                        "neighbor type; other: in the other cells of the cell type. High values",
                        "of another cell type's marker genes in cells next to that cell type",
                        "can come from transcripts assigned to the wrong cell."))))
            },
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                col <- Find(Negate(is.null), lapply(up, `[[`, "column_name"))
                feats <- trimws(unlist(strsplit(as.character(p$selected_feats %||% ""), ",",
                    fixed = TRUE)))
                feats <- feats[nzchar(feats)]
                perm <- identical(p$diff_test, "permutation")
                adv <- c(
                    if (length(feats)) paste0(", selected_feats = ", arg(feats)),
                    if (!identical(as.numeric(p$minimum_unique_cells %||% 1), 1))
                        paste0(", minimum_unique_cells = ", arg(p$minimum_unique_cells)),
                    if (!identical(as.numeric(p$minimum_unique_int_cells %||% 1), 1))
                        paste0(", minimum_unique_int_cells = ", arg(p$minimum_unique_int_cells)),
                    if (!identical(p$mean_method %||% "arithmic", "arithmic"))
                        paste0(", mean_method = ", arg(p$mean_method)),
                    if (!identical(as.numeric(p$offset %||% 0.1), 0.1))
                        paste0(", offset = ", arg(p$offset)),
                    if (!isTRUE(p$exclude_selected_cells_from_test %||% TRUE))
                        ", exclude_selected_cells_from_test = FALSE",
                    if (perm && !identical(as.numeric(p$seed_number %||% 1234), 1234))
                        paste0(", seed_number = ", arg(p$seed_number)))
                paste0("icf <- findInteractionChangedFeats(g, expression_values = ",
                    arg(.values_of(p, up)), ", ",
                    "cluster_column = ", arg(col),
                    ", spatial_network_name = ", .code_value(.network_of(p, up)), ", diff_test = ", arg(p$diff_test),
                    ", nr_permutations = ", arg(p$nr_permutations),
                    ", adjust_method = ", arg(p$adjust_method), paste(adv, collapse = ""),
                    ", do_parallel = FALSE)\n",
                    "icf_genes <- icf$ICFscores[nr_select >= ", arg(p$min_cells),
                    " & int_nr_select >= ", arg(p$min_cells),
                    " & abs(log2fc) >= ", arg(p$min_log2fc),
                    " & p.adj <= ", arg(p$max_padj), "]")
            }
        )
    )
)

.analysis_help_icf <- function() list(
    icf_test = list(
        diff_test = paste0(
            "Statistical test that compares cells of one type next to a second type with cells of ",
            "the first type that are not. Only permutation works for GiottoDisk data; limma, ",
            "t.test and wilcox are offered for data in memory."),
        nr_permutations = paste0(
            "Number of random shuffles in the permutation test. More permutations give more ",
            "precise p-values but take much longer; for example, 1000 took about 30 minutes for ",
            "2,000 cells."),
        adjust_method = paste0(
            "Correction of the p-values for testing many genes and cell type pairs. fdr and BH: ",
            "control the false discovery rate. bonferroni and holm: stricter. none: raw p-values."),
        min_log2fc = paste0(
            "Minimum absolute log2 fold change for a gene to be listed. A log2 fold change of 1 ",
            "means twice as high (or half as high) in cells next to the neighbor type. Changing ",
            "it filters the result without rerunning the test."),
        max_padj = paste0(
            "Maximum adjusted p-value for a gene to be listed, for example 0.05. Changing it ",
            "filters the result without rerunning the test."),
        min_cells = paste0(
            "Minimum number of cells on each side of a comparison (next to the neighbor type, and ",
            "not) for a result to be listed. Changing it filters the result without rerunning the ",
            "test."),
        selected_feats = paste0(
            "Genes to test, separated by commas, for example CD3E, EPCAM, COL1A1. Testing fewer ",
            "genes takes less time. Empty: all genes."),
        minimum_unique_cells = paste0(
            "Minimum number of cells of the cell type on each side of a comparison (linked to the ",
            "neighbor type, and not) for the pair to be tested. For example, 10 skips a pair when ",
            "fewer than 10 cells of the cell type touch the neighbor type. Raising it tests fewer ",
            "pairs and leaves out pairs based on few cells; 1 tests every pair."),
        minimum_unique_int_cells = paste0(
            "Minimum number of cells of the neighbor type linked to the cell type for the pair to ",
            "be tested. For example, 5 skips a pair when fewer than 5 cells of the neighbor type ",
            "touch the cell type. Raising it tests fewer pairs; 1 tests every pair."),
        mean_method = paste0(
            "How the mean expression of each group (sel and other) is computed. arithmetic: the ",
            "average of the values. geometric: exp(mean(log(value + offset))) - offset, which ",
            "gives less weight to a few cells with very high values. Only arithmetic works ",
            "for GiottoDisk data."),
        offset = paste0(
            "Number added to both means before the log2 fold change, log2((sel + offset) / ",
            "(other + offset)); also used by the geometric mean. For example, with offset 0.1 a ",
            "gene with means 0.2 and 0 has a log2 fold change of log2(0.3 / 0.1) = 1.6. A larger ",
            "offset shrinks the fold changes of genes with low expression; a smaller one makes ",
            "them larger."),
        exclude_selected_cells_from_test = paste0(
            "Whether the other group leaves out the cells linked to the neighbor type. yes: other ",
            "holds only the cells of the cell type that are not linked to the neighbor type. no: ",
            "other holds all cells of the cell type, including the linked ones, which makes the ",
            "two groups more alike and the fold changes smaller."),
        seed_number = paste0(
            "Random seed of the permutation test. The same seed and parameters always give the ",
            "same p-values."))
)

.analysis_show_icf <- function() list(
    icf_test = list(
        nr_permutations = list(diff_test = "permutation"),
        seed_number = list(diff_test = "permutation"))
)
