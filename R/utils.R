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

# The code a window waiting for the viewer shows (adr/0028): four digits. It
# names the window; it is not a secret.
.rand_code <- function() {
    as.character(1000L + sum(utf8ToInt(.rand_id(4L)) * c(1L, 62L, 3844L, 238328L)) %% 9000L)
}

# Windows that may be connected without showing the viewer, and of those the
# ones that may wait with a code. Past either, the oldest is closed.
.lens_knocks_max  <- 16L
.lens_waiting_max <- 8L

# Seconds the window that shows the viewer has to answer that it is there
.lens_probe_wait <- 2

# Conditions kept from one of the page's actions (for_page()); past it, a count
.lens_notice_items <- 50L

# For whoever is at the R console, about what the page did there (the object
# shown changed, the viewer moved): kept in the console even inside
# for_page(), which takes the page's own messages (adr/0034)
.console_message <- function(...)
    message(structure(class = c("lens_console", "message", "condition"),
        list(message = paste0(..., "\n"), call = NULL)))

# Browser-supplied text for the console, without control characters (which
# could carry terminal escape sequences); newlines and tabs are kept
.console_text <- function(x) {
    x <- enc2utf8(paste(as.character(unlist(x)), collapse = " "))
    gsub("[\\x01-\\x08\\x0b-\\x1f\\x7f\\x{80}-\\x{9f}]", "", x, perl = TRUE)
}
