# ── Spatial interactions ─────────────────────────────────────────────────────

.analysis_entry_interactions <- function() {
    prox <- c(list(
        .num("number_of_simulations", "simulations", 1000, c(10, 10000), min = 1,
            integer = TRUE, log = TRUE),
        .param("adjust_method", "p-value adjustment", lapply(c("none", "fdr",
            "bonferroni", "BH", "holm", "hochberg", "hommel", "BY"),
            function(m) .ch(m, value = m)), "none")),
        .seed_params())
    list(
    id = "interactions", label = "Spatial interactions", order = 10, auto = FALSE,
    brief = "Which cell types are neighbors more or less often than by chance.",
    description = paste(
        "Links each cell to its neighbors in a spatial network and counts the links",
        "between each pair of cell types. The counts are compared with random",
        "relabelings of the cells: a log2 enrichment above 0 means two types are",
        "neighbors more often than chance, below 0 less often.",
        "Click a square of the heatmap to show only the cells of that pair of types."),
    inputs = c("a categorical cell type column (object or Preprocessing tab)",
        "spatial locations"),
    outputs = c("log2 enrichment and p-values for each pair of cell types (heatmap)"),
    steps = list(
        groups = .step_groups(input = NULL),
        spatial_network = .step_network(input = "groups"),
        proximity = list(
            label = "Proximity enrichment", input = "spatial_network",
            fun = "cellProximityEnrichment",
            params = prox,
            run = function(g, p) g,
            result = function(g, p, before) {
                cpe <- Giotto::cellProximityEnrichment(g, spatial_network_name = .lens_net(p),
                    cluster_column = "lens_group",
                    number_of_simulations = p$number_of_simulations,
                    adjust_method = p$adjust_method, set_seed = p$set_seed,
                    seed_number = p$seed_number)
                e <- as.data.frame(cpe$enrichm_res)
                ab <- strsplit(as.character(e$unified_int), "--", fixed = TRUE)
                tab <- data.frame(pair = as.character(e$unified_int),
                    type_a = vapply(ab, `[`, "", 1L), type_b = vapply(ab, `[`, "", 2L),
                    type_int = e$type_int, original = e$original,
                    simulations = e$simulations, enrichm = e$enrichm,
                    p_adj_higher = e$p.adj_higher, p_adj_lower = e$p.adj_lower)
                types <- sort(unique(c(tab$type_a, tab$type_b)))
                if (length(types) > 2L) {
                    m <- matrix(0, length(types), length(types), dimnames = list(types, types))
                    m[cbind(tab$type_a, tab$type_b)] <- tab$enrichm
                    m[cbind(tab$type_b, tab$type_a)] <- tab$enrichm
                    types <- types[stats::hclust(stats::dist(m))$order]
                }
                list(enrichment = tab, order = types,
                    summary = sprintf("%d pairs: %d enriched, %d depleted (p < 0.05)",
                        nrow(tab), sum(tab$p_adj_higher < 0.05), sum(tab$p_adj_lower < 0.05)))
            },
            view = function(res, p) list(panels = list(list(id = "proximity",
                title = "Proximity enrichment",
                spec = .proximity_spec(res$enrichment, res$order)))),
            pick = function(value, res, p) list(pair = c(unlist(value$type_a)[1L],
                unlist(value$type_b)[1L])),
            code = function(p, up) {
                col <- Find(Negate(is.null), lapply(up, `[[`, "column_name"))
                paste0("cpe <- cellProximityEnrichment(g, spatial_network_name = ",
                    "", .code_value(.network_of(p, up)), ", cluster_column = ", .code_value(col), ", ",
                    paste(.code_args(prox, p, c("number_of_simulations", "adjust_method",
                        "set_seed", "seed_number"), list(seed_number = list(set_seed = "TRUE"))),
                        collapse = ", "), ")\n",
                    "cellProximityHeatmap(g, CPscore = cpe, order_cell_types = TRUE, scale = FALSE)")
            }
        )
    ))
}

.analysis_help_interactions <- function() list(
    proximity = list(
        number_of_simulations = paste0(
            "Number of times the cell type labels are shuffled at random to estimate how often ",
            "two types would be neighbors by chance. More simulations give more precise p-values ",
            "but take longer; the smallest p-value possible is 1 / (simulations + 1), for example ",
            "0.001 with 1000."),
        adjust_method = paste0(
            "Correction of the p-values for testing many pairs of cell types. none: raw p-values. ",
            "fdr and BH: control the false discovery rate. bonferroni and holm: stricter, and ",
            "need more simulations to give small p-values."),
        set_seed = .seed_help("the random relabelings")$set_seed,
        seed_number = .seed_help("the random relabelings")$seed_number)
)

.analysis_show_interactions <- function() list(
    proximity = list(seed_number = list(set_seed = "TRUE"))
)
