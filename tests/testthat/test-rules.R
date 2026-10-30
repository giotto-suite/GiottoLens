ctx <- local({
    g <- expand.grid(x = 0:9 + 0.5, y = 0:9 + 0.5)
    list(x = g$x, y = g$y, meta = data.frame(
        score = g$x, lab = factor(ifelse(seq_len(100) %% 2 == 0, "a", "b")),
        name = paste0("n", seq_len(100))))
})

test_that("rules evaluate like the viewer does", {
    sq <- rbind(c(0, 0), c(3, 0), c(3, 3), c(0, 3))
    expect_identical(sum(.eval_rule(lens_polygon(sq), ctx)), 9L)
    expect_identical(sum(.eval_rule(lens_polygon(sq, negate = TRUE), ctx)), 91L)
    expect_identical(sum(.eval_rule(lens_polygon(list(sq, sq + 5)), ctx)), 18L)
    expect_identical(sum(.eval_rule(lens_polygon(sq, space = c(x = "score", y = "score")), ctx)), 30L)
    expect_identical(sum(.eval_rule(lens_range("score", 2, 4), ctx)), 20L)
    expect_identical(sum(.eval_rule(lens_categories("lab", "a"), ctx)), 50L)
    expect_identical(sum(.eval_rule(lens_compare("score", ">", 8), ctx)), 20L)
    expect_identical(sum(.eval_rule(lens_compare("name", "contains", "N9"), ctx)), 11L)
    stroke <- list(kind = "stroke", space = "spatial",
        params = list(path = list(c(0.5, 0.5), c(9.5, 0.5)), radius = 0.1))
    expect_identical(sum(.eval_rule(stroke, ctx)), 10L)
    ids <- list(kind = "ids", params = list(mask = .encode_mask(c(3L, 7L), 100)))
    expect_identical(which(.eval_rule(ids, ctx)), c(3L, 7L))
    u <- list(kind = "union", params = list(parts = list(lens_range("score", 0, 1), ids)))
    expect_identical(sum(.eval_rule(u, ctx)), 12L)   # x = 0.5 column, plus cells 3 and 7
})

test_that("rules combine with or / and", {
    rules <- list(a = lens_range("score", 0, 5), b = lens_range("score", 3, 10))
    expect_identical(sum(.combine_rules(rules, ctx, "and")), 20L)
    expect_identical(sum(.combine_rules(rules, ctx, "or")), 100L)
    expect_identical(sum(.combine_rules(list(), ctx, "or")), 0L)
})

test_that("invalid rules are rejected with a clear message", {
    expect_error(.validate_rule(list(kind = "blob")), "kind")
    expect_error(lens_polygon(rbind(c(0, 0), c(1, 1))), "at least 3")
    expect_error(lens_range("x", "a", 2), "numeric")
    expect_error(lens_compare("x", "~", 1), "op is one of")
    expect_error(.eval_rule(lens_range("nope", 0, 1), ctx), "no metadata column 'nope'")
})

test_that("lens_bbox selects a box and checks its bounds", {
    expect_identical(sum(.eval_rule(lens_bbox(c(0, 3, 0, 3)), ctx)), 9L)
    expect_identical(sum(.eval_rule(lens_bbox(c(0, 3, 0, 3), negate = TRUE), ctx)), 91L)
    expect_error(lens_bbox(c(3, 0, 0, 3)), "min < max")
    expect_error(lens_bbox(1:3), "xmin, xmax")
})

test_that("rules have readable summaries", {
    expect_match(.rule_summary(lens_polygon(rbind(c(0, 0), c(3, 0), c(3, 3)))),
        "^polygon, 1 ring, 3 vertices, x 0 to 3, y 0 to 3$")
    expect_identical(.rule_summary(lens_range("score", 2, 4)), "score from 2 to 4")
    expect_identical(.rule_summary(lens_categories("lab", c("a", "b"), negate = TRUE)),
        "not (lab in {a, b})")
    expect_identical(.rule_summary(lens_compare("name", "contains", "n9")), "name contains 'n9'")
    expect_match(.rule_summary(lens_union(lens_range("score", 0, 1), lens_range("score", 5, 6))), "; or ")
})

test_that("rule code recreates the same cells", {
    ids <- paste0("c", seq_along(ctx$x))
    rules <- list(
        lens_polygon(rbind(c(0, 0), c(3, 0), c(3, 3), c(0, 3)), negate = TRUE),
        lens_range("score", 2, 4),
        lens_categories("lab", "a"),
        lens_compare("name", "contains", "n9"),
        lens_union(lens_bbox(c(0, 2, 0, 2)), lens_range("score", 8, 10)),
        list(kind = "stroke", params = list(path = list(c(0.5, 0.5), c(9.5, 0.5)), radius = 0.1))
    )
    for (r in rules) {
        code <- .rule_code(r, ids, ctx)
        r2 <- .resolve_cells(eval(parse(text = code)), ids)
        expect_identical(which(.eval_rule(r2, ctx)), which(.eval_rule(r, ctx)), info = code)
    }
})

test_that("lens_cells resolves IDs to the viewer's cells", {
    ids <- paste0("c", 1:10)
    r <- .resolve_cells(lens_union(lens_cells(c("c2", "c5")), lens_cells("c9")), ids)
    expect_identical(r$params$parts[[1]]$kind, "ids")
    expect_identical(which(.eval_rule(r, list(x = 1:10, y = 1:10))), c(2L, 5L, 9L))
    expect_warning(.resolve_cells(lens_cells(c("c1", "zz")), ids), "1 ID")
})
