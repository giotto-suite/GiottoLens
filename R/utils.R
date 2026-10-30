# Base R only gained `%||%` in 4.4.0
`%||%` <- function(x, y) if (is.null(x)) y else x

# Random [A-Za-z0-9] string from the OS's random source. The viewer token is
# the server's access check (adr/0006), so it must not come from R's RNG:
# set.seed(), and the seeds Giotto functions set by default, make that
# predictable. Without /dev/urandom (Windows), R's RNG is reseeded from the
# clock and the user's RNG state restored.
.rand_id <- function(n = 16L) {
    chars <- c(letters, LETTERS, 0:9)
    if (!file.exists("/dev/urandom")) {
        seed <- get0(".Random.seed", envir = globalenv(), inherits = FALSE)
        on.exit(if (is.null(seed)) rm(".Random.seed", envir = globalenv())
            else assign(".Random.seed", seed, envir = globalenv()), add = TRUE)
        set.seed(NULL)
        return(paste(sample(chars, n, replace = TRUE), collapse = ""))
    }
    con <- file("/dev/urandom", "rb", raw = TRUE)
    on.exit(close(con), add = TRUE)
    out <- integer(0)
    while (length(out) < n) {
        b <- as.integer(readBin(con, "raw", 2L * n))
        out <- c(out, b[b < 248L] %% 62L)   # 248 = 4 * 62: no modulo bias
    }
    paste(chars[out[seq_len(n)] + 1L], collapse = "")
}

# Browser-supplied text for the console, without control characters (which
# could carry terminal escape sequences); newlines and tabs are kept
.console_text <- function(x) {
    x <- enc2utf8(paste(as.character(unlist(x)), collapse = " "))
    gsub("[\\x01-\\x08\\x0b-\\x1f\\x7f\\x{80}-\\x{9f}]", "", x, perl = TRUE)
}
