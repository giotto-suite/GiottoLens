# Base R only gained `%||%` in 4.4.0
`%||%` <- function(x, y) if (is.null(x)) y else x

# Random [A-Za-z0-9] string from a cryptographic random source. The viewer
# token is the server's access check (adr/0006), so it must not come from R's
# RNG: set.seed(), and the seeds Giotto functions set by default, make that
# predictable, and a clock-and-PID reseed holds at most 32 bits. nanonext
# (through mirai) draws from Mbed TLS's DRBG on every platform, Windows
# included, and leaves R's RNG state alone.
.rand_id <- function(n = 16L) {
    chars <- c(letters, LETTERS, 0:9)
    out <- integer(0)
    while (length(out) < n) {
        b <- as.integer(nanonext::random(2L * n, convert = FALSE))
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
