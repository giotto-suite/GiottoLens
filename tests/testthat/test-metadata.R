test_that(".write_metadata writes rows in cell order with category codes", {
    dir <- tempfile("meta"); dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)
    ids <- c("c1", "c2", "c3")
    expect_error(.write_metadata(data.frame(id = 1), dir, ids), "cell_ID")
    expect_error(.write_metadata(data.frame(cell_ID = "c1", v = 1), dir, NULL), "no cells")
    expect_error(.write_metadata(data.frame(cell_ID = "zz", v = 1), dir, ids), "no cell_ID matches")
    expect_error(.write_metadata(data.frame(cell_ID = "c1"), dir, ids), "no columns")

    meta <- data.frame(cell_ID = c("c3", "c1", "extra"), a.b = c(3L, 1L, 9L),
        a_b = c(0.5, 1, 2), lab = c("y", NA, "z"), check.names = FALSE)
    expect_message(out <- .write_metadata(meta, dir, ids), "1 metadata row")
    msg <- out$msg
    expect_identical(out$table$a_b_1, c(1, NA, 0.5))
    expect_match(msg$url, "^session/metadata/cell_meta_[0-9]+\\.parquet$")
    expect_identical(msg$n, 3L)
    expect_identical(vapply(msg$columns, `[[`, "", "name"), c("a_b", "a_b_1", "lab"))
    expect_identical(vapply(msg$columns, `[[`, "", "kind"), c("continuous", "continuous", "categorical"))
    expect_identical(vapply(msg$columns, function(cl) isTRUE(cl$numeric), TRUE), c(TRUE, TRUE, FALSE))
    # Levels come from the cells in the viewer ("z" is only on the extra row)
    expect_identical(unlist(msg$columns[[3]]$levels), "y")

    written <- arrow::read_parquet(file.path(dir, basename(msg$url)))
    expect_identical(written$a_b, c(1, NA, 3))          # integers are continuous; c2 → NA
    expect_identical(written$a_b_1, c(1, NA, 0.5))
    expect_identical(written$lab, c(-1L, -1L, 0L))

    urls <- basename(msg$url)
    for (k in 1:4) {
        Sys.sleep(0.01)
        urls <- c(urls, basename(suppressMessages(.write_metadata(meta, dir, ids))$msg$url))
    }
    expect_identical(sort(list.files(dir)), sort(utils::tail(urls, 3L)))
})

test_that(".write_metadata shows numeric columns as categories when asked", {
    dir <- tempfile("meta"); dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)
    ids <- c("c1", "c2", "c3", "c4")
    meta <- data.frame(cell_ID = ids, clus = c(2, 10, 2, NA), n = c(100000L, 5L, 5L, 7L),
        lab = c("a", "b", "a", "b"))
    out <- .write_metadata(meta, dir, ids, types = c(clus = "categorical", n = "categorical",
        lab = "categorical"))
    cols <- out$msg$columns
    expect_identical(vapply(cols, `[[`, "", "kind"), rep("categorical", 3L))
    expect_identical(unlist(cols[[1]]$levels), c("2", "10"))          # numeric order
    expect_identical(unlist(cols[[2]]$levels), c("5", "7", "100000")) # no 1e+05
    expect_true(isTRUE(cols[[1]]$numeric))
    expect_null(cols[[3]]$numeric)
    written <- arrow::read_parquet(file.path(dir, basename(out$msg$url)))
    expect_identical(written$clus, c(0L, 1L, 0L, -1L))
    # rules in R see the categories
    expect_identical(as.character(out$table$clus), c("2", "10", "2", NA))

    many <- data.frame(cell_ID = paste0("c", 1:1001), v = as.double(1:1001))
    expect_error(.write_metadata(many, dir, many$cell_ID, types = c(v = "categorical")),
        "1001 distinct values")
})

test_that(".parse_col_types maps aliases and rejects unknown types", {
    expect_null(.parse_col_types(NULL))
    expect_identical(.parse_col_types(c("a", "b")), c(a = NA_character_, b = NA_character_))
    expect_identical(.parse_col_types(list(a = "factor", b = "numeric", "c")),
        c(a = "categorical", b = "continuous", c = NA_character_))
    expect_error(.parse_col_types(list(a = "nope")), "unknown column type")
})
