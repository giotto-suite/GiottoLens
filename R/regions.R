# ── Regions and region differential expression (adr/0020) ──────────────────
#
# Regions are named sets of cell IDs that R holds for the object shown. A
# comparison between two of them, or one and every other cell, runs as a job
# (adr/0025) over the object the jobs' daemon holds, and is docked as a volcano
# plot whose genes colour the cells by item key (adr/0024).

.check_region_name <- function(name, where) {
    if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(trimws(name)))
        stop("[", where, "] `name` must be one non-empty string", call. = FALSE)
    trimws(name)
}

# A job's `fun` (R/jobs.R): Giotto::findScranMarkers() between two sets of
# cells; `b = NULL` is every other cell. Cells in both sets are left out of
# both. Its metadata column is added to the job's copy of the object only.
.region_de <- function(g, a, b, values, spat_unit, feat_type) {
    ids <- as.character(GiottoClass::spatIDs(g, spat_unit = spat_unit))
    in_a <- ids %in% a
    in_b <- if (is.null(b)) !in_a else ids %in% b
    both <- in_a & in_b
    grp <- rep(NA_character_, length(ids))
    grp[in_a & !both] <- "lens_a"
    grp[in_b & !both] <- "lens_b"
    n_a <- sum(grp == "lens_a", na.rm = TRUE)
    n_b <- sum(grp == "lens_b", na.rm = TRUE)
    if (n_a < 2L || n_b < 2L)
        stop("each group needs at least 2 cells in the expression; found ", n_a, " and ", n_b)
    g <- GiottoClass::addCellMetadata(g, spat_unit = spat_unit, feat_type = feat_type,
        new_metadata = data.frame(cell_ID = ids, lens_de_group = grp),
        by_column = TRUE, column_cell_ID = "cell_ID")
    res <- Giotto::findScranMarkers(g, spat_unit = spat_unit, feat_type = feat_type,
        expression_values = values, cluster_column = "lens_de_group",
        group_1 = "lens_a", group_1_name = "lens_a",
        group_2 = "lens_b", group_2_name = "lens_b", verbose = FALSE)
    t <- as.data.frame(Find(function(d) identical(as.character(d$cluster[1L]), "lens_a"), res))
    list(table = data.frame(gene = as.character(t$feats), logFC = as.numeric(t$summary.logFC),
            p_value = as.numeric(t$p.value), FDR = as.numeric(t$FDR)),
        n_a = n_a, n_b = n_b, n_both = sum(both))
}

# The expression source a comparison reads, from the catalog: `values` (an
# expression name), or "normalized"
.de_source <- function(cat, values, feat_type, where) {
    expr <- Filter(function(s) s$slot == "expression" &&
        (is.null(feat_type) || identical(s$feat_type, feat_type)), cat$sources)
    if (!length(expr))
        stop("[", where, "] the object shown has no expression to compare", call. = FALSE)
    if (!is.null(values) && (!is.character(values) || length(values) != 1L || is.na(values)))
        stop("[", where, "] `values` must be one expression name", call. = FALSE)
    want <- values %||% "normalized"
    hit <- Find(function(s) identical(s$name, want), expr)
    if (is.null(hit))
        stop("[", where, "] no '", want, "' expression",
            if (is.null(values)) "; normalize the object (Giotto::normalizeGiotto()) or pass `values`",
            "; available: ", paste(unique(vapply(expr, `[[`, "", "name")), collapse = ", "),
            call. = FALSE)
    hit
}

# Volcano plot of a two-group test: logFC against -log10 FDR, the 10 genes
# with the lowest FDR labelled; a click on a point colours cells by that gene
# (param `pick`, see panels/spec.js)
.de_volcano <- function(tab, a, b, fdr = 0.05) {
    up <- paste("higher in", a)
    down <- paste("higher in", b)
    d <- data.frame(gene = tab$gene, logFC = round(tab$logFC, 4), FDR = signif(tab$FDR, 3),
        neg_log10_FDR = round(-log10(pmax(tab$FDR, 1e-300)), 3))
    d$direction <- ifelse(!is.na(tab$FDR) & tab$FDR < fdr,
        ifelse(tab$logFC > 0, up, down), "not significant")
    ord <- order(tab$FDR)
    d$label <- ""
    top <- utils::head(ord[d$direction[ord] != "not significant"], 10L)
    d$label[top] <- d$gene[top]
    x <- list(field = "logFC", type = "quantitative", title = sprintf("logFC (%s vs %s)", a, b))
    y <- list(field = "neg_log10_FDR", type = "quantitative", title = "-log10 FDR")
    spec <- list(
        `$schema` = "https://vega.github.io/schema/vega-lite/v5.json",
        title = sprintf("%s vs %s", a, b),
        layer = list(
            list(
                params = list(list(name = "pick",
                    select = list(type = "point", fields = list("gene"), on = "click",
                        clear = "dblclick"))),
                mark = list(type = "circle", size = 22, cursor = "pointer"),
                encoding = list(x = x, y = y,
                    color = list(field = "direction", type = "nominal",
                        scale = list(domain = list(up, down, "not significant"),
                            range = list("#d62728", "#1f77b4", "#6b7280")),
                        legend = list(title = NULL, orient = "bottom")),
                    tooltip = list(list(field = "gene"), list(field = "logFC"),
                        list(field = "FDR")))),
            list(
                transform = list(list(filter = "datum.label != ''")),
                mark = list(type = "text", dy = -8, fontSize = 10),
                encoding = list(x = x, y = y, text = list(field = "label")))))
    list(spec = spec, data = d)
}
