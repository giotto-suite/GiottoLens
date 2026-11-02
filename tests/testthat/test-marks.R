# A square grid of `n` x `n` bins, `spacing` apart, turned by `angle` degrees
square_grid <- function(n, spacing, angle, jitter = 0) {
    g <- expand.grid(col = seq_len(n) - 1L, row = seq_len(n) - 1L)
    a <- angle * pi / 180
    list(
        x = spacing * (g$col * cos(a) - g$row * sin(a)) + 100 + jitter * sin(seq_len(nrow(g))),
        y = spacing * (g$col * sin(a) + g$row * cos(a)) - 40 + jitter * cos(seq_len(nrow(g))),
        row = g$row, col = g$col
    )
}

test_that(".grid_fit recovers the spacing and rotation of a square grid", {
    for (angle in c(0, 7.5, -20, 33)) {
        g   <- square_grid(20, 8, angle, jitter = 0.5)
        fit <- .grid_fit(g$x, g$y, g$row, g$col)
        expect_equal(fit$size, 8, tolerance = 1e-3)
        expect_equal(fit$angle, angle, tolerance = 1e-2)
    }
    # Turned by more than 45 degrees the square looks the same as turned by less
    g <- square_grid(10, 2, 80)
    expect_equal(.grid_fit(g$x, g$y, g$row, g$col)$angle, -10, tolerance = 1e-6)
    # Flipped y (images count rows down) is still a square grid
    g <- square_grid(10, 2, 0)
    expect_equal(.grid_fit(g$x, -g$y, g$row, g$col)$size, 2)
})

test_that(".grid_fit refuses grids that are not square", {
    # Visium: spots on a hexagonal grid, columns of even rows even
    g <- expand.grid(col = 0:20, row = 0:20)
    g <- g[(g$row + g$col) %% 2 == 0, ]
    x <- g$col * 50
    y <- g$row * 50 * sqrt(3)
    expect_null(.grid_fit(x, y, g$row, g$col))
    # Rectangular bins
    g <- square_grid(10, 2, 0)
    expect_null(.grid_fit(g$x * 2, g$y, g$row, g$col))
    # Positions that do not follow the indices
    expect_null(.grid_fit(sin(g$col * 7 + g$row) * 50, cos(g$row * 3) * 50, g$row, g$col))
    # One row only
    expect_null(.grid_fit(1:5, rep(0, 5), rep(0L, 5), 0:4))
})

test_that(".nn_spacing is the median distance to the nearest neighbour", {
    g <- square_grid(40, 3, 15)
    expect_equal(.nn_spacing(g$x, g$y), 3, tolerance = 1e-6)
    # A few isolated cells and duplicates do not move it
    expect_equal(.nn_spacing(c(g$x, 1e4, g$x[1:5]), c(g$y, 1e4, g$y[1:5])), 3, tolerance = 1e-6)
    expect_identical(.nn_spacing(1, 1), 1)
})

test_that(".cell_mark takes the user's fields, then the grid, then the spacing", {
    g <- square_grid(10, 2, 5)
    grid <- data.frame(row = g$row, col = g$col)
    m <- .cell_mark(g$x, g$y, grid)
    expect_identical(m$shape, "square")
    expect_equal(m$size, 2)
    expect_equal(m$angle, 5)
    m <- .cell_mark(g$x, g$y)
    expect_identical(m$shape, "circle")
    expect_equal(m$size, 2)
    expect_identical(m$angle, 0)
    m <- .cell_mark(g$x, g$y, grid, list(shape = "hex", size = 3))
    expect_identical(m[c("shape", "size")], list(shape = "hex", size = 3))
    expect_equal(m$angle, 5)
})

test_that(".check_mark rejects malformed marks", {
    expect_null(.check_mark(NULL))
    expect_identical(.check_mark(list(size = 2)), list(size = 2))
    expect_error(.check_mark("square"), "list with any of")
    expect_error(.check_mark(list(width = 2)), "list with any of")
    expect_error(.check_mark(list(shape = "star")), "circle")
    expect_error(.check_mark(list(size = -1)), "positive")
    expect_error(.check_mark(list(angle = NA_real_)), "degrees")
})

test_that(".drawn_mark puts the viewer's setting over the launch mark", {
    bins <- list(mark = list(shape = "square", size = 2, angle = 10), marks = TRUE)
    segmented <- list(mark = list(shape = "circle", size = 10, angle = 0), marks = FALSE)
    expect_identical(.drawn_mark(bins), bins$mark)
    expect_null(.drawn_mark(segmented))
    expect_identical(.drawn_mark(segmented, list(show = TRUE)), segmented$mark)
    expect_identical(.drawn_mark(bins, list(shape = "circle", size = 3)),
        list(shape = "circle", size = 3, angle = 10))
    expect_null(.drawn_mark(bins, list(show = FALSE, size = 3)))
    expect_identical(.mark_text(bins$mark), "squares 2 across at 10 degrees")
    expect_identical(.mark_text(segmented$mark), "circles 10 across")
    expect_identical(.mark_text(NULL), "dots")
})
