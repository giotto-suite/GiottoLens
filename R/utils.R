# Base R only gained `%||%` in 4.4.0
`%||%` <- function(x, y) if (is.null(x)) y else x

.rand_id <- function(n = 16L) {
    paste(sample(c(letters, LETTERS, 0:9), n, replace = TRUE), collapse = "")
}
