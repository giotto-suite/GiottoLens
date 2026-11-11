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
                    integer = TRUE))
            ),
            run = function(g, p) g,
            result = function(g, p, before) {
                icf <- Giotto::findInteractionChangedFeats(g, expression_values = "normalized",
                    cluster_column = "lens_group", spatial_network_name = "lens_spatial",
                    diff_test = p$diff_test, nr_permutations = p$nr_permutations,
                    adjust_method = p$adjust_method, do_parallel = FALSE)
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
                paste0("icf <- findInteractionChangedFeats(g, expression_values = \"normalized\", ",
                    "cluster_column = ", arg(col),
                    ", spatial_network_name = \"lens_spatial\", diff_test = ", arg(p$diff_test),
                    ", nr_permutations = ", arg(p$nr_permutations),
                    ", adjust_method = ", arg(p$adjust_method), ", do_parallel = FALSE)\n",
                    "icf_genes <- icf$ICFscores[nr_select >= ", arg(p$min_cells),
                    " & int_nr_select >= ", arg(p$min_cells),
                    " & abs(log2fc) >= ", arg(p$min_log2fc),
                    " & p.adj <= ", arg(p$max_padj), "]")
            }
        )
    )
)
