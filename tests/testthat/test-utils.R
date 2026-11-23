test_that("tokens come from a cryptographic random source, not R's RNG", {
    set.seed(1); a <- .rand_id(24L); state <- .Random.seed
    set.seed(1); b <- .rand_id(24L)
    expect_false(identical(a, b))
    expect_identical(.Random.seed, state)            # the user's RNG is untouched
    expect_match(a, "^[A-Za-z0-9]{24}$")
})

test_that("browser text reaches the console without control characters", {
    ctl <- function(...) intToUtf8(c(...), multiple = TRUE)
    x <- paste0("ok", ctl(27), "[31m red", ctl(7), "\n\tcaf\u00e9", ctl(0x9b))
    expect_identical(.console_text(x), "ok[31m red\n\tcaf\u00e9")
    expect_identical(.console_text(NULL), "")
    expect_identical(.console_text(list("a", 1)), "a 1")
})

test_that("the code of a waiting window is four digits", {
    codes <- replicate(200L, .rand_code())
    expect_true(all(grepl("^[1-9][0-9]{3}$", codes)))
    expect_gt(length(unique(codes)), 150L)
})
