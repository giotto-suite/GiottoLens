test_that("worker helpers score clusterings and count calls", {
    set.seed(1)
    x <- rbind(matrix(stats::rnorm(60), ncol = 2), matrix(stats::rnorm(60, 4), ncol = 2), c(9, 9))
    d <- as.matrix(stats::dist(x))
    cl <- c(rep(1L, 30), rep(2L, 30), 3L)
    expected <- vapply(seq_along(cl), function(i) {
        a <- if (sum(cl == cl[i]) > 1L) mean(d[i, cl == cl[i] & seq_along(cl) != i]) else NA
        b <- min(vapply(setdiff(unique(cl), cl[i]), function(k) mean(d[i, cl == k]), 1))
        if (is.na(a)) 0 else (b - a) / max(a, b)
    }, 1)
    expect_equal(.aw_silhouette(d, cl), mean(expected))

    w <- new.env()
    w$kept <- list()
    w$key <- "k1"
    progress <- tempfile()
    old <- mget(c(".lens_a", ".lens_progress", ".lens_progress_file", ".lens_progress_t",
        ".lens_tick"), envir = globalenv(), ifnotfound = list(NULL))
    on.exit(for (n in names(old)) if (is.null(old[[n]]))
        suppressWarnings(rm(list = n, envir = globalenv())) else assign(n, old[[n]], globalenv()),
        add = TRUE)
    assign(".lens_a", w, envir = globalenv())
    assign(".lens_progress", .job_fun(.lens_progress), envir = globalenv())
    assign(".lens_progress_file", progress, envir = globalenv())
    h <- .aw_helpers()
    h$.lens_keep(list(a = 1))
    expect_identical(h$.lens_kept(), list(a = 1))
    out <- h$.lens_count_calls({
        for (i in 1:3) stats::setNames(1, "a")
        "done"
    }, "stats", "setNames", 3, "calls")
    expect_identical(out, "done")
    expect_identical(readLines(progress), "3\t3\tcalls")
    expect_false(inherits(stats::setNames, "functionWithTrace"))
})
