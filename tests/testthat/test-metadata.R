test_that(".write_metadata writes rows in cell order with category codes", {
    dir <- tempfile("meta"); dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)
    ids <- c("c1", "c2", "c3")
    expect_error(.write_metadata(data.frame(id = 1), dir, ids), "cell_ID")
    expect_error(.write_metadata(data.frame(cell_ID = "c1", v = 1), dir, NULL), "no polygons")
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
    expect_identical(vapply(msg$columns, `[[`, "", "kind"), c("categorical", "continuous", "categorical"))
    # Levels come from the cells in the viewer ("z" is only on the extra row)
    expect_identical(unlist(msg$columns[[3]]$levels), "y")

    written <- arrow::read_parquet(file.path(dir, basename(msg$url)))
    expect_identical(written$a_b, c(0L, -1L, 1L))      # levels "1", "3"; c2 → NA
    expect_identical(written$a_b_1, c(1, NA, 0.5))
    expect_identical(written$lab, c(-1L, -1L, 0L))

    Sys.sleep(0.01)
    msg2 <- suppressMessages(.write_metadata(meta, dir, ids))$msg
    expect_identical(list.files(dir), basename(msg2$url))
})

test_that(".parse_col_types maps aliases and rejects unknown types", {
    expect_null(.parse_col_types(NULL))
    expect_identical(.parse_col_types(c("a", "b")), c(a = NA_character_, b = NA_character_))
    expect_identical(.parse_col_types(list(a = "factor", b = "numeric", "c")),
        c(a = "categorical", b = "continuous", c = NA_character_))
    expect_error(.parse_col_types(list(a = "nope")), "unknown column type")
})
