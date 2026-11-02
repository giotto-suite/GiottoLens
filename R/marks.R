# ── Cell marks (adr/0010) ────────────────────────────────────────────────────
#
# A mark is how the viewer draws a cell when there is no polygon to draw: a
# circle, square or hexagon `size` data units across, turned by `angle`
# degrees. Zoomed out the viewer draws dots; marks take over once they are a
# few pixels wide.

.mark_shapes <- c("circle", "square", "hex")

# A mark given to launch_lens(): a list with any of shape, size and angle
.check_mark <- function(mark) {
    if (is.null(mark)) return(NULL)
    if (!is.list(mark) || is.null(names(mark)) ||
        !all(names(mark) %in% c("shape", "size", "angle")))
        stop("[launch_lens] `mark` is a list with any of shape, size and angle",
            call. = FALSE)
    num1 <- function(v) is.numeric(v) && length(v) == 1L && is.finite(v)
    if (!is.null(mark$shape) &&
        !(is.character(mark$shape) && length(mark$shape) == 1L && mark$shape %in% .mark_shapes))
        stop("[launch_lens] mark shape is \"circle\", \"square\" or \"hex\"", call. = FALSE)
    if (!is.null(mark$size) && !(num1(mark$size) && mark$size > 0))
        stop("[launch_lens] mark size is a positive number in data units", call. = FALSE)
    if (!is.null(mark$angle) && !num1(mark$angle))
        stop("[launch_lens] mark angle is a number of degrees", call. = FALSE)
    mark
}

# The mark for cells at `x`, `y`: the user's fields first, then a fit of the
# bin grid (`grid`: row and col per cell, from array_row/array_col), then the
# spacing of neighbouring cells as a circle's diameter.
.cell_mark <- function(x, y, grid = NULL, mark = NULL) {
    fit <- if (!is.null(grid)) .grid_fit(x, y, grid$row, grid$col)
    list(
        shape = mark$shape %||% if (!is.null(fit)) "square" else "circle",
        size  = mark$size  %||% fit$size %||% .nn_spacing(x, y),
        angle = mark$angle %||% fit$angle %||% 0
    )
}

# Bins on a square grid: x and y as linear functions of the array column and
# row give the bin spacing and the grid's rotation exactly. NULL unless one
# step along a row and one along a column are equally long, at right angles,
# and every bin sits within half a bin of the fit (Visium's hexagonal spot
# grid does not).
.grid_fit <- function(x, y, row, col) {
    ok <- is.finite(x) & is.finite(y) & is.finite(row) & is.finite(col)
    if (sum(ok) < 3L) return(NULL)
    X  <- cbind(1, as.numeric(col[ok]), as.numeric(row[ok]))
    fx <- stats::lm.fit(X, x[ok])
    fy <- stats::lm.fit(X, y[ok])
    if (fx$rank < 3L) return(NULL)
    u  <- unname(c(fx$coefficients[2L], fy$coefficients[2L]))  # one column on
    v  <- unname(c(fx$coefficients[3L], fy$coefficients[3L]))  # one row on
    lu <- sqrt(sum(u^2))
    lv <- sqrt(sum(v^2))
    if (abs(lu - lv) > 0.02 * max(lu, lv) || abs(sum(u * v)) > 0.02 * lu * lv)
        return(NULL)
    size <- (lu + lv) / 2
    if (max(abs(fx$residuals), abs(fy$residuals)) > size / 2) return(NULL)
    # A square turned by 90 degrees is the same square
    angle <- atan2(u[2L], u[1L]) * 180 / pi
    list(size = size, angle = ((angle + 45) %% 90) - 45)
}

# Median distance from a cell to its nearest neighbour, over up to `n_sample`
# cells spread evenly through the x order. Each cell is compared with the
# cells in an x window around it, found by binary search; coincident cells
# are skipped.
.nn_spacing <- function(x, y, n_sample = 1000L) {
    n <- length(x)
    if (n < 2L) return(1)
    o  <- order(x)
    xs <- x[o]
    ys <- y[o]
    area <- diff(range(x)) * diff(range(y))
    w <- if (area > 0) 3 * sqrt(area / n) else max(diff(range(x)), diff(range(y))) / n * 3
    nearest <- function(i, w) {
        j <- seq.int(findInterval(xs[i] - w, xs) + 1L, findInterval(xs[i] + w, xs))
        d2 <- (xs[j] - xs[i])^2 + (ys[j] - ys[i])^2
        d2 <- d2[d2 > 0]
        if (length(d2)) sqrt(min(d2)) else NA_real_
    }
    d <- vapply(unique(round(seq(1, n, length.out = min(n, n_sample)))), function(i) {
        di <- nearest(i, w)
        # Nearer cells may lie outside the window when this one is isolated
        if (is.na(di) || di > w) nearest(i, Inf) else di
    }, numeric(1L))
    s <- stats::median(d, na.rm = TRUE)
    if (is.na(s)) 1 else s
}
