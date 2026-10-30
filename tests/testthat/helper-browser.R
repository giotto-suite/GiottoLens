# Headless Chrome via chromote, recording console errors and exceptions.
lens_browser <- function(url, width = 1200, height = 800) {
    testthat::skip_on_cran()
    testthat::skip_if_not_installed("chromote")
    if (is.null(tryCatch(chromote::find_chrome(), error = function(e) NULL)))
        testthat::skip("Chrome not available")
    b <- chromote::ChromoteSession$new(width = width, height = height)
    errors <- new.env()
    errors$list <- character()
    add <- function(x) errors$list <- c(errors$list, x)
    b$Runtime$enable()
    b$Runtime$consoleAPICalled(callback_ = function(m) {
        if (m$type %in% c("error", "assert"))
            add(paste(vapply(m$args, function(a)
                as.character(a$value %||% a$description %||% ""), ""), collapse = " "))
    })
    b$Runtime$exceptionThrown(callback_ = function(m)
        add(m$exceptionDetails$exception$description %||% m$exceptionDetails$text))
    b$Page$navigate(url, wait_ = FALSE)
    list(
        session = b,
        errors  = function() errors$list,
        js = function(code) b$Runtime$evaluate(code, awaitPromise = TRUE,
            returnByValue = TRUE)$result$value,
        close = function() b$close()
    )
}

browser_wait <- function(br, cond_js, timeout = 30) {
    pump_until(function() isTRUE(tryCatch(br$js(cond_js), error = function(e) FALSE)),
        timeout)
}

# Drag the mouse along a closed path given in canvas pixel coordinates
browser_drag <- function(br, pts) {
    off <- br$js("(() => { const r = document.getElementById('deck-canvas').getBoundingClientRect(); return [r.left, r.top]; })()")
    send <- function(type, p) br$session$Input$dispatchMouseEvent(
        type = type, x = off[[1]] + p[[1]], y = off[[2]] + p[[2]],
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mousePressed", pts[[1]])
    for (p in pts[-1]) send("mouseMoved", p)
    send("mouseReleased", pts[[length(pts)]])
}
