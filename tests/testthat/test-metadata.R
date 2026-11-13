test_that(".write_metadata writes one file per column in cell order", {
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
    expect_null(msg$url)
    expect_identical(msg$n, 3L)
    expect_identical(vapply(msg$columns, `[[`, "", "name"), c("a_b", "a_b_1", "lab"))
    expect_identical(vapply(msg$columns, `[[`, "", "kind"), c("continuous", "continuous", "categorical"))
    expect_identical(vapply(msg$columns, function(cl) isTRUE(cl$numeric), TRUE), c(TRUE, TRUE, FALSE))
    # Levels come from the cells in the viewer ("z" is only on the extra row)
    expect_identical(unlist(msg$columns[[3]]$levels), "y")
    urls <- vapply(msg$columns, `[[`, "", "url")
    expect_match(urls, "^session/metadata/(a_b|a_b_1|lab)-[0-9a-f]{32}\\.parquet$")
    expect_setequal(list.files(dir), basename(urls))

    col <- function(i) arrow::read_parquet(file.path(dir, basename(urls[i])))$value
    expect_identical(col(1), c(1, NA, 3))          # integers are continuous; c2 -> NA
    expect_identical(col(2), c(1, NA, 0.5))
    expect_identical(col(3), c(-1L, -1L, 0L))
    # R reads columns back from the files
    expect_identical(.read_meta_column(dir, msg$columns[[2]]), c(1, NA, 0.5))
    expect_identical(.read_meta_column(dir, msg$columns[[3]]), factor(c(NA, NA, "y")))

    # Files are named by content: the same values keep their file
    meta$a_b <- c(5, 6, 7)
    msg2 <- suppressMessages(.write_metadata(meta, dir, ids))$msg
    urls2 <- vapply(msg2$columns, `[[`, "", "url")
    expect_identical(urls2[-2], urls[-2])
    expect_false(urls2[2] == urls[2])
    expect_length(list.files(dir), 4L)
    .prune_meta_files(dir, urls2)
    expect_setequal(list.files(dir), basename(urls2))
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
    expect_identical(arrow::read_parquet(.meta_column_path(dir, cols[[1]]))$value, c(0L, 1L, 0L, -1L))
    expect_identical(out$values, list(clus = c(2, 10), n = c(5L, 7L, 100000L)))
    # rules in R see the categories
    expect_identical(as.character(.read_meta_column(dir, cols[[1]])), c("2", "10", "2", NA))

    # A kept type over the level limit is not applied: the push goes on
    many <- data.frame(cell_ID = paste0("c", 1:1001), v = as.double(1:1001), w = 1)
    expect_warning(out <- .write_metadata(many, dir, many$cell_ID,
        types = c(v = "categorical", w = "categorical")), "1001 distinct values")
    expect_identical(vapply(out$msg$columns, `[[`, "", "kind"), c("continuous", "categorical"))
    expect_identical(out$dropped, "v")
})

test_that("numeric category labels keep their format", {
    expect_identical(.numeric_labels(c(-2, 0.5, 1e-7, 1e5, 123456789012, 1/3)),
        c("-2", "0.5", "0.0000001", "100000", "123456789012", "0.333333333333333"))
})

test_that(".retype_meta rewrites one column's file and back exactly", {
    dir <- tempfile("meta"); dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)
    ids <- c("c1", "c2", "c3", "c4")
    x <- c(0.1 + 0.2, 1/3, NA, 0.1 + 0.2)
    meta <- data.frame(cell_ID = ids, x = x, lab = c("a", "b", "a", NA))
    out <- .write_metadata(meta, dir, ids)
    before <- list.files(dir)
    cat <- .retype_meta(dir, out$msg$columns[[1]], "categorical")
    expect_identical(cat$entry$kind, "categorical")
    expect_identical(unlist(cat$entry$levels), c("0.3", "0.333333333333333"))
    expect_identical(setdiff(list.files(dir), before), basename(cat$entry$url))   # one new file
    expect_identical(arrow::read_parquet(.meta_column_path(dir, cat$entry))$value,
        c(0L, 1L, -1L, 0L))                                       # 0.1 + 0.2 < 1/3
    back <- .retype_meta(dir, cat$entry, "continuous", cat$values)
    expect_identical(.read_meta_column(dir, back$entry), x)
    expect_identical(back$entry$url, out$msg$columns[[1]]$url)   # the same values, the same file
    expect_null(back$values)

    many <- data.frame(cell_ID = paste0("c", 1:1001), v = as.double(1:1001))
    out <- .write_metadata(many, dir, many$cell_ID)
    expect_error(.retype_meta(dir, out$msg$columns[[1]], "categorical"), "1001 distinct values")
})

test_that("text whose values are numbers can be continuous", {
    dir <- tempfile("meta"); dir.create(dir)
    on.exit(unlink(dir, recursive = TRUE), add = TRUE)
    ids <- c("c1", "c2", "c3", "c4")
    meta <- data.frame(cell_ID = ids, num = c("1", "2.5", NA, "10"),
        lab = c("a", "1", "b", "2"), flag = c(TRUE, FALSE, TRUE, NA))
    out <- .write_metadata(meta, dir, ids)
    cols <- out$msg$columns
    expect_true(cols[[1]]$number_text)
    expect_null(cols[[2]]$number_text)
    expect_null(cols[[3]]$number_text)

    expect_warning(out <- .write_metadata(meta, dir, ids,
        types = c(num = "continuous", lab = "continuous", flag = "continuous")),
        "`lab` has values that are not numbers")
    cols <- out$msg$columns
    expect_identical(vapply(cols, `[[`, "", "kind"), c("continuous", "categorical", "continuous"))
    expect_true(cols[[1]]$numeric)
    expect_identical(.read_meta_column(dir, cols[[1]]), c(1, 2.5, NA, 10))
    expect_identical(.read_meta_column(dir, cols[[3]]), c(1, 0, 1, NA))
    expect_identical(out$dropped, "lab")

    # Retyped from its file, it is numeric from then on
    txt <- .write_metadata(meta, dir, ids)$msg$columns
    re <- .retype_meta(dir, txt[[1]], "continuous")
    expect_identical(re$entry$kind, "continuous")
    expect_true(re$entry$numeric)
    expect_identical(.read_meta_column(dir, re$entry), c(1, 2.5, NA, 10))
    expect_null(re$values)
    expect_error(.retype_meta(dir, txt[[2]], "continuous"), "values that are not numbers")
})

test_that(".merge_meta adds columns and replaces one of the same name in place", {
    old <- list(n = 3L, columns = list(list(name = "a", url = "1"), list(name = "b", url = "2")))
    new <- list(n = 3L, columns = list(list(name = "c", url = "3"), list(name = "a", url = "4")))
    m <- .merge_meta(old, new)
    expect_identical(vapply(m$columns, `[[`, "", "name"), c("a", "b", "c"))
    expect_identical(m$columns[[1]]$url, "4")
    expect_identical(.merge_meta(NULL, new)$columns, new$columns)
})

test_that(".parse_col_types maps aliases and rejects unknown types", {
    expect_null(.parse_col_types(NULL))
    expect_identical(.parse_col_types(c("a", "b")), c(a = NA_character_, b = NA_character_))
    expect_identical(.parse_col_types(list(a = "factor", b = "numeric", "c")),
        c(a = "categorical", b = "continuous", c = NA_character_))
    expect_error(.parse_col_types(list(a = "nope")), "unknown column type")
})
