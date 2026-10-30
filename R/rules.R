# ── Selection rules ──────────────────────────────────────────────────────────
#
# A selection is one rule per source (spatial lasso, scatter lasso, histogram,
# metadata filter, R), combined with OR, or AND in crossfilter mode. The
# viewer evaluates rules in the browser; this is the same evaluation in R,
# over the cell centroids and the pushed metadata, so a rule set from R (or
# read back from the viewer) resolves to cells without a browser. Keep it in
# step with inst/viewer-src/selection/rules.ts (adr/0001). Interactive
# selection stays here and in the browser, not in spatRelate() (adr/0007).

.rule_kinds <- c("polygon", "stroke", "range", "categories", "compare", "ids", "union",
    "cells")  # cells: R-side only, resolved to ids by .resolve_cells()
.compare_ops <- c("=", "!=", ">", "<", "contains")

.validate_rule <- function(rule, where = "select") {
    bad <- function(...) stop("[", where, "] ", ..., call. = FALSE)
    if (!is.list(rule) || !is.character(rule$kind) || length(rule$kind) != 1L ||
        !rule$kind %in% .rule_kinds)
        bad("a rule needs `kind`, one of: ", paste(.rule_kinds, collapse = ", "))
    p <- rule$params
    switch(rule$kind,
        polygon = {
            if (!length(p$rings)) bad("polygon rule needs params$rings")
            for (r in p$rings) if (length(r) < 3L) bad("each ring needs at least 3 points")
            sp <- rule$space
            if (!(identical(sp, "spatial") || (is.list(sp) && is.character(sp$x) && is.character(sp$y))))
                bad("polygon space is \"spatial\" or list(x = <column>, y = <column>)")
        },
        stroke = if (!length(p$path) || !is.numeric(p$radius)) bad("stroke rule needs params$path and params$radius"),
        range = {
            if (!is.character(rule$space)) bad("range rule needs `space`, a column name")
            if (!is.numeric(p$min) || !is.numeric(p$max)) bad("range rule needs numeric params$min and params$max")
        },
        categories = if (!is.character(rule$space) || !length(p$values)) bad("categories rule needs `space` and params$values"),
        compare = {
            if (!is.character(rule$space)) bad("compare rule needs `space`, a column name")
            if (!isTRUE(p$op %in% .compare_ops)) bad("compare op is one of: ", paste(.compare_ops, collapse = ", "))
        },
        ids = if (!is.character(p$mask)) bad("ids rule needs params$mask"),
        cells = if (!length(p$ids)) bad("cells rule needs params$ids"),
        union = for (part in p$parts) .validate_rule(part, where)
    )
    invisible(rule)
}

# Rings arrive as lists of [x, y] pairs (JSON) or as two-column matrices (R)
.as_ring <- function(r) {
    if (is.matrix(r)) return(r)
    do.call(rbind, lapply(r, function(p) as.numeric(unlist(p))))
}

# Even-odd point-in-polygon over many points; only points in the ring's
# bounding box are tested
.pip <- function(ring, x, y) {
    out  <- logical(length(x))
    cand <- which(x >= min(ring[, 1L]) & x <= max(ring[, 1L]) &
                  y >= min(ring[, 2L]) & y <= max(ring[, 2L]))
    if (!length(cand)) return(out)
    x <- x[cand]; y <- y[cand]
    inside <- logical(length(cand))
    n <- nrow(ring)
    j <- n
    for (i in seq_len(n)) {
        xi <- ring[i, 1L]; yi <- ring[i, 2L]; xj <- ring[j, 1L]; yj <- ring[j, 2L]
        cross <- ((yi > y) != (yj > y)) & (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
        inside <- xor(inside, cross)
        j <- i
    }
    out[cand] <- inside & !is.na(inside)
    out
}

.seg_dist2 <- function(x, y, a, b) {
    dx <- b[1L] - a[1L]; dy <- b[2L] - a[2L]
    len2 <- dx * dx + dy * dy
    t <- if (len2 > 0) pmin(1, pmax(0, ((x - a[1L]) * dx + (y - a[2L]) * dy) / len2)) else 0
    (a[1L] + t * dx - x)^2 + (a[2L] + t * dy - y)^2
}

# ctx: list(x, y, meta) with meta a data.frame in cell order (or NULL)
.eval_rule <- function(rule, ctx) {
    n <- length(ctx$x)
    col <- function(name) {
        v <- ctx$meta[[name]]
        if (is.null(v)) stop("[select] no metadata column '", name, "'", call. = FALSE)
        v
    }
    p <- rule$params
    m <- switch(rule$kind,
        polygon = {
            sp <- rule$space
            px <- if (identical(sp, "spatial")) ctx$x else col(sp$x)
            py <- if (identical(sp, "spatial")) ctx$y else col(sp$y)
            Reduce(`|`, lapply(p$rings, function(r) .pip(.as_ring(r), px, py)), logical(n))
        },
        stroke = {
            path <- .as_ring(p$path)
            r2 <- p$radius^2
            hit <- logical(n)
            segs <- if (nrow(path) == 1L) list(c(1L, 1L)) else lapply(2:nrow(path), function(k) c(k - 1L, k))
            for (s in segs) hit <- hit | .seg_dist2(ctx$x, ctx$y, path[s[1L], ], path[s[2L], ]) <= r2
            hit
        },
        range = { v <- col(rule$space); !is.na(v) & v >= p$min & v <= p$max },
        categories = { v <- col(rule$space); !is.na(v) & as.character(v) %in% unlist(p$values) },
        compare = .eval_compare(col(rule$space), p$op, as.character(p$value)),
        ids = seq_len(n) %in% .decode_mask(p$mask, n),
        union = Reduce(`|`, lapply(p$parts, .eval_rule, ctx = ctx), logical(n))
    )
    if (isTRUE(rule$negate)) !m else m
}

.eval_compare <- function(v, op, value) {
    if (op == "contains")
        return(!is.na(v) & grepl(tolower(value), tolower(as.character(v)), fixed = TRUE))
    if (is.numeric(v) && !is.factor(v)) {
        b <- as.numeric(value)
        out <- switch(op, "=" = v == b, "!=" = v != b, ">" = v > b, "<" = v < b)
    } else {
        s <- as.character(v)
        out <- switch(op, "=" = s == value, "!=" = s != value,
            ">" = as.numeric(s) > as.numeric(value), "<" = as.numeric(s) < as.numeric(value))
    }
    !is.na(out) & out
}

# Combine rules (a named list, one per source) into a logical vector
.combine_rules <- function(rules, ctx, combine = c("or", "and")) {
    combine <- match.arg(combine)
    if (!length(rules)) return(logical(length(ctx$x)))
    masks <- lapply(rules, .eval_rule, ctx = ctx)
    Reduce(if (combine == "and") `&` else `|`, masks)
}

# ── Rule helpers ─────────────────────────────────────────────────────────────

#' Build selection rules for a GiottoLens viewer
#'
#' Rules describe a selection the way the viewer's tools do, so a selection
#' made in R and one drawn in the browser go through the same code. Pass the
#' result to `viewer$select()`.
#'
#' @param ring Polygon vertices: a two-column matrix (x, y), or a list of
#'   such matrices for several rings (their union).
#' @param space `"spatial"` (cell centroids), or `c(x = "<col>", y = "<col>")`
#'   for a lasso in a scatter of two metadata columns.
#' @param column Metadata column name.
#' @param min,max Inclusive bounds.
#' @param values Category labels.
#' @param op One of `"="`, `"!="`, `">"`, `"<"`, `"contains"`.
#' @param value Value to compare with.
#' @param negate Select the complement.
#' @return A rule (list).
#' @examples
#' lens_polygon(rbind(c(0, 0), c(100, 0), c(100, -100)))
#' lens_range("nr_feats", 50, 200)
#' @export
lens_polygon <- function(ring, space = "spatial", negate = FALSE) {
    rings <- if (is.matrix(ring)) list(ring) else ring
    sp <- if (identical(space, "spatial")) "spatial" else as.list(space)[c("x", "y")]
    .validate_rule(list(kind = "polygon", space = sp,
        params = list(rings = lapply(rings, function(r)
            lapply(seq_len(nrow(r)), function(i) unname(as.numeric(r[i, 1:2]))))),
        negate = negate), "lens_polygon")
}

#' @rdname lens_polygon
#' @param bounds `c(xmin, xmax, ymin, ymax)`, e.g. from `viewer$view_bounds()`
#'   ("select what is on screen")
#' @export
lens_bbox <- function(bounds, negate = FALSE) {
    b <- as.numeric(bounds)
    if (length(b) != 4L || anyNA(b) || b[1L] >= b[2L] || b[3L] >= b[4L])
        stop("[lens_bbox] bounds must be c(xmin, xmax, ymin, ymax) with min < max",
            call. = FALSE)
    lens_polygon(rbind(c(b[1L], b[3L]), c(b[2L], b[3L]), c(b[2L], b[4L]), c(b[1L], b[4L])),
        negate = negate)
}

#' @rdname lens_polygon
#' @export
lens_range <- function(column, min, max, negate = FALSE) {
    .validate_rule(list(kind = "range", space = column,
        params = list(min = min, max = max), negate = negate), "lens_range")
}

#' @rdname lens_polygon
#' @export
lens_categories <- function(column, values, negate = FALSE) {
    .validate_rule(list(kind = "categories", space = column,
        params = list(values = as.list(as.character(values))), negate = negate),
        "lens_categories")
}

#' @rdname lens_polygon
#' @export
lens_compare <- function(column, op, value, negate = FALSE) {
    .validate_rule(list(kind = "compare", space = column,
        params = list(op = op, value = as.character(value)), negate = negate),
        "lens_compare")
}

#' @rdname lens_polygon
#' @param ... Rules to combine (cells matching any of them), e.g. several lassos
#' @export
lens_union <- function(..., negate = FALSE) {
    parts <- list(...)
    for (p in parts) .validate_rule(p, "lens_union")
    list(kind = "union", params = list(parts = parts), negate = negate)
}

# lens_cells() rules name cells by ID; the viewer works in cell indices, so
# they become `ids` mask rules (inside unions too) before validation.
.resolve_cells <- function(rule, cell_ids) {
    if (identical(rule$kind, "cells")) {
        ids <- as.character(unlist(rule$params$ids))
        idx <- match(ids, cell_ids)
        if (anyNA(idx))
            warning("[select] ", sum(is.na(idx)), " ID(s) are not cells in the viewer and ",
                "were ignored", call. = FALSE)
        return(list(kind = "ids", negate = rule$negate,
            params = list(mask = .encode_mask(unique(idx[!is.na(idx)]), length(cell_ids)))))
    }
    if (identical(rule$kind, "union"))
        rule$params$parts <- lapply(rule$params$parts, .resolve_cells, cell_ids = cell_ids)
    rule
}

# ── Describing rules ─────────────────────────────────────────────────────────

.fmt_num <- function(x) format(signif(as.numeric(x), 4), big.mark = ",", trim = TRUE)

# One-line description of a rule
.rule_summary <- function(rule) {
    p <- rule$params
    s <- switch(rule$kind %||% "",
        polygon = {
            rings <- lapply(p$rings, .as_ring)
            xy <- do.call(rbind, rings)
            sp <- if (identical(rule$space, "spatial") || is.null(rule$space)) "" else
                sprintf(" in %s \u00d7 %s", rule$space$x, rule$space$y)
            sprintf("polygon%s, %d ring%s, %d vertices, x %s to %s, y %s to %s", sp,
                length(rings), if (length(rings) > 1L) "s" else "", nrow(xy),
                .fmt_num(min(xy[, 1L])), .fmt_num(max(xy[, 1L])),
                .fmt_num(min(xy[, 2L])), .fmt_num(max(xy[, 2L])))
        },
        stroke = sprintf("brush, %d points, radius %s", length(p$path), .fmt_num(p$radius)),
        range = sprintf("%s from %s to %s", rule$space, .fmt_num(p$min), .fmt_num(p$max)),
        categories = sprintf("%s in {%s}", rule$space, paste(unlist(p$values), collapse = ", ")),
        compare = sprintf("%s %s %s", rule$space, p$op, encodeString(as.character(p$value), quote = "'")),
        ids = "a list of cells",
        union = paste(vapply(p$parts, .rule_summary, ""), collapse = "; or "),
        "unknown rule"
    )
    if (isTRUE(rule$negate)) paste0("not (", s, ")") else s
}

# R code that recreates a rule with the lens_*() builders
.rule_code <- function(rule, cell_ids = NULL, ctx = NULL) {
    p <- rule$params
    neg <- if (isTRUE(rule$negate)) ", negate = TRUE" else ""
    num <- function(x) paste(format(as.numeric(x), digits = 8, trim = TRUE), collapse = ", ")
    ring_code <- function(r) {
        r <- .as_ring(r)
        f <- function(x) format(as.numeric(x), digits = 8, trim = TRUE)
        sprintf("rbind(%s)", paste(sprintf("c(%s, %s)", f(r[, 1L]), f(r[, 2L])), collapse = ", "))
    }
    switch(rule$kind,
        polygon = {
            rings <- vapply(p$rings, ring_code, "")
            ring <- if (length(rings) == 1L) rings else sprintf("list(%s)", paste(rings, collapse = ", "))
            sp <- if (identical(rule$space, "spatial") || is.null(rule$space)) "" else
                sprintf(', space = c(x = "%s", y = "%s")', rule$space$x, rule$space$y)
            sprintf("lens_polygon(%s%s%s)", ring, sp, neg)
        },
        range = sprintf('lens_range("%s", %s, %s%s)', rule$space, num(p$min), num(p$max), neg),
        categories = sprintf('lens_categories("%s", c(%s)%s)', rule$space,
            paste0('"', unlist(p$values), '"', collapse = ", "), neg),
        compare = sprintf('lens_compare("%s", "%s", %s%s)', rule$space, p$op,
            encodeString(as.character(p$value), quote = '"'), neg),
        union = sprintf("lens_union(%s%s)",
            paste(vapply(p$parts, .rule_code, "", cell_ids = cell_ids, ctx = ctx), collapse = ",\n    "), neg),
        # Brush strokes and cell lists have no builder: the cells they cover
        {
            idx <- if (!is.null(ctx)) which(.eval_rule(rule, ctx))
            ids <- cell_ids[idx]
            if (!length(ids)) "NULL  # no cells"
            else sprintf("lens_cells(c(%s))", paste0('"', ids, '"', collapse = ", "))
        }
    )
}

#' @rdname lens_polygon
#' @param ids Cell IDs (for `lens_cells()`; resolved when passed to
#'   `viewer$select()`)
#' @export
lens_cells <- function(ids, negate = FALSE) {
    list(kind = "cells", params = list(ids = as.list(as.character(ids))), negate = negate)
}

#' @export
print.lens_rules <- function(x, ...) {
    if (!nrow(x)) {
        cat("No selection rules\n")
        return(invisible(x))
    }
    print(as.data.frame(unclass(x))[, c("source", "kind", "cells", "summary")], row.names = FALSE, right = FALSE)
    cat(sprintf("\nCombined with %s: %s cells selected\n",
        if (attr(x, "combine") == "and") "AND (cross-filter)" else "OR",
        format(attr(x, "selected"), big.mark = ",")))
    invisible(x)
}
