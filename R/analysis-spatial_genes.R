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
        "Click a gene in the table or the bar chart to color the cells by its expression."),
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
                    min = 1, max = 100, step = 1),
                .advanced(.param("adjust_method", "p-value adjustment", lapply(
                    c("fdr", "BH", "BY", "holm", "hochberg", "hommel", "bonferroni", "none"),
                    function(m) .ch(m, value = m)), "fdr")),
                .advanced(.param("implementation", "implementation (binSpect)", list(
                    .ch("fast", value = "fast"),
                    .ch("data.table", value = "data.table", disk = FALSE),
                    .ch("simple", value = "simple", disk = FALSE),
                    .ch("matrix", value = "matrix", disk = FALSE)), "fast")),
                .advanced(.param("do_fisher_test", "Fisher test", list(
                    .ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE")),
                .advanced(.param("kmeans_algo", "k-means algorithm", list(
                    .ch("kmeans", value = "kmeans"),
                    .ch("kmeans_arma", value = "kmeans_arma"),
                    .ch("kmeans_arma_subset", value = "kmeans_arma_subset")), "kmeans")),
                .advanced(.num("nstart", "k-means random starts", 3, c(1, 20), min = 1,
                    integer = TRUE)),
                .advanced(.num("iter_max", "k-means iterations", 10, c(1, 100), min = 1,
                    integer = TRUE)),
                .advanced(.num("extreme_nr", "top and bottom cells", 50, c(5, 500), min = 1,
                    integer = TRUE)),
                .advanced(.num("sample_nr", "sampled cells", 50, c(5, 1000), min = 2,
                    integer = TRUE)),
                .advanced(.num("seed", "seed", 1234, c(1, 10000), min = 0, integer = TRUE,
                    auto = TRUE)),
                .advanced(.param("reduce_network", "one direction per link", list(
                    .ch(FALSE, "no"), .ch(TRUE, "yes")), "FALSE")),
                .advanced(.param("calc_hub", "count hub cells", list(
                    .ch(FALSE, "no"), .ch(TRUE, "yes")), "FALSE")),
                .advanced(.num("hub_min_int", "hub: high neighbors", 3, c(1, 20), min = 1,
                    integer = TRUE)),
                .advanced(.param("get_av_expr", "average high expression", list(
                    .ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE")),
                .advanced(.param("get_high_expr", "count high cells", list(
                    .ch(TRUE, "yes"), .ch(FALSE, "no")), "TRUE")),
                .advanced(.num("group_size", "genes per group", "auto", c(2, 500), min = 2,
                    integer = TRUE, auto = TRUE)),
                .advanced(.text_param("spatial_network_k", "kNN k values",
                    placeholder = "for example 5, 10, 20")),
                .advanced(.param("summarize", "combine k values by", list(
                    .ch("p.value", value = "p.value"),
                    .ch("adj.p.value", value = "adj.p.value")), "p.value")),
                .advanced(.param("null", "null (Moran's I)", list(
                    .ch("permutation", value = "permutation"),
                    .ch("covariate", value = "covariate")), "permutation")),
                .advanced(.text_param("covariate", "covariate", default = "libsize",
                    placeholder = "libsize or a cell metadata column")),
                .advanced(.num("n_groups", "covariate groups", 10, c(2, 50), min = 2,
                    integer = TRUE)),
                .advanced(.param("weighted", "use link weights", list(
                    .ch(FALSE, "no"), .ch(TRUE, "yes")), "FALSE")),
                .advanced(.text_param("metric", "distance metric (silhouetteRank)",
                    default = "euclidean")),
                .advanced(.num("rbp_p", "binarization threshold (silhouetteRank)", 0.95,
                    c(0.5, 1), min = 0, max = 1, step = 0.01)),
                .advanced(.num("examine_top", "top fraction (silhouetteRank)", 0.3, c(0.05, 1),
                    min = 0, max = 1, step = 0.05))
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
                    a <- list(bin_method = sub("binspect_", "", m, fixed = TRUE),
                        percentage_rank = p$percentage_rank, adjust_method = p$adjust_method,
                        implementation = p$implementation)
                    if (p$implementation != "fast") {
                        if (p$implementation != "matrix")
                            a$do_fisher_test <- p$do_fisher_test
                        a <- c(a, list(reduce_network = p$reduce_network,
                            get_av_expr = p$get_av_expr, get_high_expr = p$get_high_expr,
                            cores = .lens_threads()))
                        if (p$implementation == "data.table") {
                            a$calc_hub <- p$calc_hub
                            if (isTRUE(p$calc_hub)) a$hub_min_int <- p$hub_min_int
                            a$group_size <- p$group_size %||% "automatic"
                        }
                        k <- suppressWarnings(as.numeric(trimws(unlist(strsplit(
                            p$spatial_network_k %||% "", ",", fixed = TRUE)))))
                        k <- k[!is.na(k)]
                        if (length(k)) a <- c(a, list(spatial_network_k = k,
                            summarize = p$summarize))
                        if (m == "binspect_kmeans") {
                            a <- c(a, list(kmeans_algo = p$kmeans_algo, nstart = p$nstart,
                                iter_max = p$iter_max))
                            a["seed"] <- list(p$seed)
                            if (p$kmeans_algo == "kmeans_arma_subset")
                                a <- c(a, list(extreme_nr = p$extreme_nr,
                                    sample_nr = p$sample_nr))
                        }
                    }
                    do.call(Giotto::binSpect, c(list(g, expression_values = vals,
                        subset_feats = feats, spatial_network_name = .lens_net(p),
                        verbose = FALSE), a))
                } else if (m %in% c("moran", "geary")) {
                    a <- list(adjust_method = p$adjust_method, weighted = p$weighted)
                    if (m == "moran") {
                        a$null <- p$null
                        if (p$null == "covariate") {
                            cv <- trimws(p$covariate %||% "")
                            a$covariate <- if (nzchar(cv)) cv else "libsize"
                            a$n_groups <- p$n_groups
                        }
                    }
                    do.call(Giotto::spatialAutoCor, c(list(g, method = m,
                        expression_values = vals, spatial_network_name = .lens_net(p),
                        feats = feats, return_gobject = FALSE), a))
                } else {
                    mt <- trimws(p$metric %||% "")
                    Giotto::silhouetteRank(g, expression_values = vals, subset_genes = feats,
                        metric = if (nzchar(mt)) mt else "euclidean", rbp_p = p$rbp_p,
                        examine_top = p$examine_top)
                }
                if (is.list(r) && !is.data.frame(r) && !is.null(r$simple)) {
                    pv <- r$simple$p.val
                    r <- data.frame(feats = r$simple$feats, score = -log10(pv))
                    r[[if (identical(p$summarize, "adj.p.value")) "adj.p.value" else
                        "p.value"]] <- pv
                }
                r <- as.data.frame(r)
                gene <- as.character(if ("feats" %in% names(r)) r$feats else r$genes)
                score <- if ("z" %in% names(r)) r$z else if ("score" %in% names(r)) r$score
                    else if ("scores" %in% names(r)) r$scores else r$estimate
                tab <- data.frame(gene = gene, score = score)
                if ("p.value" %in% names(r)) tab$p_value <- r$p.value
                if ("adj.p.value" %in% names(r)) tab$adj_p_value <- r$adj.p.value
                for (k in intersect(c("statistic", "expected", "variance", "estimate",
                        "n_on", "odds_ratio", "av_expr", "high_expr", "hub_nr"), names(r)))
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
            pick = function(value, res, p) list(feature = unlist(value$gene)[1L]),
            view = function(res, p) list(
                panels = list(list(id = "sg_top", title = "Spatial genes",
                    spec = .sg_top_spec(res$genes, res$method))),
                tables = list(.analysis_table(res$genes, id = "sg_gene_table",
                    title = paste("Spatial genes:", res$method), feat = "gene",
                    sort = "score", note = "click a gene to color the cells by its expression"))),
            code = function(p, up) {
                arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v),
                    collapse = "")
                vals <- .values_of(p, up)
                hvf <- identical(p$feats, "hvf")
                pre <- if (hvf) "feats <- fDataDT(g)[hvf == \"yes\", feat_ID]\n" else ""
                m <- p$method
                call <- if (m %in% c("binspect_kmeans", "binspect_rank")) {
                    paste0("sg <- binSpect(g, bin_method = ",
                        arg(sub("binspect_", "", m, fixed = TRUE)),
                        ", expression_values = ", arg(vals),
                        if (hvf) ", subset_feats = feats",
                        ", spatial_network_name = ", .code_value(.network_of(p, up)), "",
                        if (m == "binspect_rank")
                            paste0(", percentage_rank = ", arg(p$percentage_rank)),
                        .sg_changed_args(.sg_binspect_args(p), .sg_binspect_defaults()), ")")
                } else if (m %in% c("moran", "geary")) {
                    paste0("sg <- spatialAutoCor(g, method = ", arg(m),
                        ", expression_values = ", arg(vals),
                        ", spatial_network_name = ", .code_value(.network_of(p, up)), "",
                        if (hvf) ", feats = feats",
                        .sg_changed_args(.sg_autocor_args(p, moran = m == "moran"),
                            .sg_autocor_defaults()), ", return_gobject = FALSE)")
                } else {
                    paste0("sg <- silhouetteRank(g, expression_values = ", arg(vals),
                        if (hvf) ", subset_genes = feats",
                        .sg_changed_args(.sg_sil_args(p), .sg_sil_defaults()), ")")
                }
                paste0(pre, call)
            }
        )
    )
)

# `p` with the entries of `defaults` it lacks
.sg_fill <- function(p, defaults) {
    miss <- setdiff(names(defaults), names(p))
    p[miss] <- defaults[miss]
    p
}

# ", name = value" for each of `args` whose value differs from `defaults`
.sg_changed_args <- function(args, defaults) {
    arg <- function(v) paste(deparse(if (is.integer(v)) as.numeric(v) else v), collapse = "")
    out <- character()
    for (k in names(args))
        if (!identical(arg(args[[k]]), arg(defaults[[k]])))
            out <- c(out, paste0(", ", k, " = ", arg(args[[k]])))
    paste(out, collapse = "")
}

# A text value, or `default` when empty
.sg_text <- function(x, default) {
    x <- trimws(x %||% "")
    if (nzchar(x)) x else default
}

# The binSpect arguments of a Spatial genes step that apply to its method
# and implementation
.sg_binspect_args <- function(p) {
    p <- .sg_fill(p, .sg_binspect_defaults())
    a <- list(adjust_method = p$adjust_method, implementation = p$implementation)
    if (identical(p$implementation, "fast")) return(a)
    if (!identical(p$implementation, "matrix")) a$do_fisher_test <- p$do_fisher_test
    a <- c(a, list(reduce_network = p$reduce_network, get_av_expr = p$get_av_expr,
        get_high_expr = p$get_high_expr))
    if (identical(p$implementation, "data.table")) {
        a$calc_hub <- p$calc_hub
        if (isTRUE(p$calc_hub)) a$hub_min_int <- p$hub_min_int
        a$group_size <- p$group_size %||% "automatic"
    }
    k <- suppressWarnings(as.numeric(.text_list(p$spatial_network_k)))
    k <- k[!is.na(k)]
    if (length(k)) a <- c(a, list(spatial_network_k = k, summarize = p$summarize))
    if (identical(p$method, "binspect_kmeans")) {
        a <- c(a, list(kmeans_algo = p$kmeans_algo, nstart = p$nstart, iter_max = p$iter_max))
        a["seed"] <- list(p$seed)
        if (identical(p$kmeans_algo, "kmeans_arma_subset"))
            a <- c(a, list(extreme_nr = p$extreme_nr, sample_nr = p$sample_nr))
    }
    a
}

.sg_binspect_defaults <- function() list(adjust_method = "fdr", implementation = "fast",
    do_fisher_test = TRUE, reduce_network = FALSE, calc_hub = FALSE, hub_min_int = 3,
    get_av_expr = TRUE, get_high_expr = TRUE, group_size = "automatic",
    spatial_network_k = NULL, summarize = "p.value", kmeans_algo = "kmeans", nstart = 3,
    iter_max = 10, seed = 1234, extreme_nr = 50, sample_nr = 50)

# The spatialAutoCor arguments of a step that apply: `moran` for the
# covariate null, `binspect` for the binarization
.sg_autocor_args <- function(p, moran = TRUE, binspect = FALSE) {
    p <- .sg_fill(p, .sg_autocor_defaults())
    a <- list()
    if (binspect) {
        a$bin_method <- p$bin_method
        if (identical(p$bin_method, "rank")) a$percentage_rank <- p$percentage_rank
    }
    if (moran || binspect) {
        a$null <- p$null
        if (identical(p$null, "covariate"))
            a <- c(a, list(covariate = .sg_text(p$covariate, "libsize"), n_groups = p$n_groups))
    }
    w <- isTRUE(p$weighted) && !(binspect && identical(p$null, "covariate"))
    c(a, list(weighted = w, adjust_method = p$adjust_method))
}

# The silhouetteRank arguments of a Spatial genes step
.sg_sil_args <- function(p) {
    p <- .sg_fill(p, .sg_sil_defaults())
    list(metric = .sg_text(p$metric, "euclidean"), rbp_p = p$rbp_p, examine_top = p$examine_top)
}

.sg_sil_defaults <- function() list(metric = "euclidean", rbp_p = 0.95, examine_top = 0.3)

.sg_autocor_defaults <- function() list(bin_method = "kmeans", percentage_rank = 30,
    null = "permutation", covariate = "libsize", n_groups = 10, weighted = FALSE,
    adjust_method = "fdr")

# Scores of the top `n` genes as bars
.sg_top_spec <- function(d, method, n = 30L) {
    d <- utils::head(d[is.finite(d$score), c("rank", "gene", "score"), drop = FALSE], n)
    list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = paste("top genes,", method), width = "container", height = "container",
        data = list(values = d),
        params = list(list(name = "pick",
            select = list(type = "point", fields = list("gene"), on = "click",
                clear = "dblclick"))),
        mark = list(type = "bar", tooltip = TRUE, cursor = "pointer"),
        encoding = list(
            y = list(field = "gene", type = "nominal", sort = as.list(d$gene), title = NULL),
            x = list(field = "score", type = "quantitative", title = "score"),
            tooltip = list(
                list(field = "rank", type = "quantitative"),
                list(field = "gene", type = "nominal"),
                list(field = "score", type = "quantitative", format = ".3g")))
    )
}

.analysis_help_spatial_genes <- function() list(
    sg_genes = list(
        method = paste0(
            "How each gene is tested for a spatial pattern. binSpect kmeans or rank: cells are ",
            "split into high and low expression of the gene (by k-means or by rank), and the test ",
            "checks whether high cells are neighbors more often than by chance. Moran's I and ",
            "Geary's C: one score per gene for how similar the expression of neighboring cells ",
            "is. silhouetteRank needs a Giotto Python environment."),
        feats = paste0(
            "Genes tested: all genes, or only the highly variable genes (faster)."),
        percentage_rank = paste0(
            "For binSpect rank. The percentage of cells with the highest expression of a gene ",
            "that count as high. For example, 30 counts the top 30% of cells. Lower values look ",
            "only at the strongest expression."),
        adjust_method = paste0(
            "How p-values are corrected for testing many genes (see stats::p.adjust). fdr and ",
            "BH: Benjamini-Hochberg false discovery rate; for example, genes with adjusted p ",
            "below 0.05 are expected to include about 5% false positives. BY: a stricter false ",
            "discovery rate. holm, hochberg, hommel and bonferroni control the chance of any ",
            "false positive and give larger adjusted p-values. none: no correction."),
        implementation = paste0(
            "How binSpect computes the test. fast: an exact two-group split of each gene and a ",
            "closed-form test of the links between high cells, with a z-score per gene. ",
            "data.table, simple, matrix: a Fisher test on the table of links between high and ",
            "low cells, with an odds ratio (estimate) per gene; they need expression in memory ",
            "and are not offered for disk-backed data. The settings below the implementation ",
            "apply to data.table, simple and matrix only."),
        do_fisher_test = paste0(
            "For the data.table and simple implementations. Whether a Fisher test is run on the ",
            "table of links between high and low cells. no: only the odds ratio (estimate) is ",
            "reported, without p-values, and genes are ranked by it; this is faster."),
        kmeans_algo = paste0(
            "The k-means algorithm that splits each gene's expression into high and low cells. ",
            "kmeans: stats::kmeans on all cells. kmeans_arma: a faster k-means from the ClusterR ",
            "package. kmeans_arma_subset: the ClusterR k-means on a sample of cells (see top and ",
            "bottom cells and sampled cells). The ClusterR choices need the ClusterR package."),
        nstart = paste0(
            "Number of random starts of k-means per gene; the best split is kept. For example, ",
            "3 runs k-means three times. More starts give a more stable split and take longer."),
        iter_max = paste0(
            "Maximum number of k-means iterations per start. For example, 10 stops each start ",
            "after 10 updates. Raise it when k-means does not converge."),
        extreme_nr = paste0(
            "For kmeans_arma_subset. Number of cells with the highest and with the lowest ",
            "expression of the gene that are always included in the sample. For example, 50 ",
            "includes the top 50 and the bottom 50 cells. Higher values give a split closer to ",
            "k-means on all cells."),
        sample_nr = paste0(
            "For kmeans_arma_subset. Total number of cells sampled per gene for k-means. For ",
            "example, 50 runs k-means on 50 cells. Higher values give a split closer to k-means ",
            "on all cells and take longer."),
        seed = paste0(
            "Seed of the random number generator for k-means. The same seed gives the same ",
            "split each run; another seed can give slightly different results. Empty: no seed ",
            "is set."),
        reduce_network = paste0(
            "Whether each link of the spatial network is counted once, as stored. no: each link ",
            "is counted in both directions (cell A to B and B to A)."),
        calc_hub = paste0(
            "For the data.table implementation. Whether hub cells are counted per gene (hub_nr ",
            "column): high cells with at least 'hub: high neighbors' high neighbors."),
        hub_min_int = paste0(
            "Number of high neighbors a high cell needs to count as a hub cell. For example, 3 ",
            "counts high cells with 3 or more high neighbors. Higher values count fewer hubs."),
        get_av_expr = paste0(
            "Whether the average expression of each gene in its high cells is reported ",
            "(av_expr column)."),
        get_high_expr = paste0(
            "Whether the number of high cells of each gene is reported (high_expr column)."),
        group_size = paste0(
            "For the data.table implementation. Number of genes tested together in one group. ",
            "For example, 50 tests 50 genes at a time. Larger groups use more memory; a group ",
            "size that leaves a single gene in a group fails. Empty: automatic (a tenth of the ",
            "genes, between 2 and 200)."),
        spatial_network_k = paste0(
            "Comma-separated k values, for example 5, 10, 20. binSpect then builds a kNN network ",
            "for each k instead of using the Spatial network step, tests each gene on every ",
            "network, and combines the p-values per gene; the score is -log10 of the combined ",
            "p-value. Empty: the network of the Spatial network step."),
        summarize = paste0(
            "With kNN k values. Whether the p-values or the adjusted p-values of the k networks ",
            "are combined per gene."),
        null = paste0(
            "The random placement the scores are compared with. permutation: the gene's values ",
            "placed at random over the cells. covariate: values placed at random within groups ",
            "of cells with a similar covariate, so a pattern that only follows the covariate ",
            "(for example library size or cell type) does not count as spatial."),
        covariate = paste0(
            "For the covariate null. libsize: the total raw counts of each cell. Or the name of ",
            "a cell metadata column, for example cell_type. A numeric column is cut into ",
            "'covariate groups' groups; a categorical one is used as is."),
        n_groups = paste0(
            "For the covariate null with a numeric covariate. Number of groups of equal size the ",
            "cells are split into by the covariate. For example, 10 groups cells by the deciles ",
            "of library size. More groups follow the covariate more closely."),
        weighted = paste0(
            "Whether the links of the spatial network are weighted by their weight column, ",
            "1 / (1 + distance), so closer cells count more. no: every link counts the same."),
        metric = paste0(
            "Distance between cell locations used by silhouetteRank, for example euclidean."),
        rbp_p = paste0(
            "silhouetteRank. Fractional threshold, between 0 and 1, that splits each gene into ",
            "expressing and non-expressing cells. For example, 0.95. Another value changes which ",
            "cells count as expressing and so the score of each gene."),
        examine_top = paste0(
            "silhouetteRank. Top fraction of cells evaluated with the silhouette score. For ",
            "example, 0.3 evaluates the top 30% of cells. Lower values look only at the ",
            "strongest expression."))
)

.analysis_show_spatial_genes <- function() {
    bs <- c("binspect_kmeans", "binspect_rank")
    legacy <- c("data.table", "simple", "matrix")
    km <- list(method = "binspect_kmeans", implementation = legacy)
    list(sg_genes = list(
        percentage_rank = list(method = "binspect_rank"),
        adjust_method = list(method = c(bs, "moran", "geary")),
        implementation = list(method = bs),
        do_fisher_test = list(method = bs, implementation = c("data.table", "simple")),
        kmeans_algo = km, nstart = km, iter_max = km, seed = km,
        extreme_nr = c(km, list(kmeans_algo = "kmeans_arma_subset")),
        sample_nr = c(km, list(kmeans_algo = "kmeans_arma_subset")),
        reduce_network = list(method = bs, implementation = legacy),
        calc_hub = list(method = bs, implementation = "data.table"),
        hub_min_int = list(method = bs, implementation = "data.table", calc_hub = "TRUE"),
        get_av_expr = list(method = bs, implementation = legacy),
        get_high_expr = list(method = bs, implementation = legacy),
        group_size = list(method = bs, implementation = "data.table"),
        spatial_network_k = list(method = bs, implementation = legacy),
        summarize = list(method = bs, implementation = legacy),
        null = list(method = "moran"),
        covariate = list(method = "moran", null = "covariate"),
        n_groups = list(method = "moran", null = "covariate"),
        weighted = list(method = c("moran", "geary")),
        metric = list(method = "silhouette"),
        rbp_p = list(method = "silhouette"),
        examine_top = list(method = "silhouette")))
}
