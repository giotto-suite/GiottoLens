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

# Drag the mouse along a closed path given in canvas pixel coordinates.
# `modifiers`: CDP bitmask, Alt 1, Ctrl 2, Meta 4, Shift 8
browser_drag <- function(br, pts, modifiers = 0L) {
    off <- br$js("(() => { const r = document.getElementById('deck-canvas').getBoundingClientRect(); return [r.left, r.top]; })()")
    send <- function(type, p) br$session$Input$dispatchMouseEvent(
        type = type, x = off[[1]] + p[[1]], y = off[[2]] + p[[2]], modifiers = modifiers,
        button = "left", buttons = if (type == "mouseReleased") 0L else 1L, clickCount = 1L)
    send("mousePressed", pts[[1]])
    for (p in pts[-1]) send("mouseMoved", p)
    send("mouseReleased", pts[[length(pts)]])
}

# Click a dock tab by its title. A panel's content is mounted the first time
# its tab is shown, so a panel behind another tab has none until then. Two
# frames first: a panel just added moves the tabs when the dock lays out.
dock_tab <- function(br, title) {
    at <- br$js(sprintf("new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))).then(() => { const t = [...document.querySelectorAll('.dv-tab')].find(t => t.textContent.trim() === '%s')?.getBoundingClientRect(); return t ? [t.left + t.width / 2, t.top + t.height / 2] : null; })", title))
    if (is.null(at)) stop("no dock tab '", title, "'", call. = FALSE)
    for (type in c("mousePressed", "mouseReleased"))
        br$session$Input$dispatchMouseEvent(type = type, x = at[[1]], y = at[[2]], button = "left",
            buttons = if (type == "mousePressed") 1L else 0L, clickCount = 1L)
}
