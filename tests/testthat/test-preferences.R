local_pref_file <- function(env = parent.frame()) {
    f <- tempfile(fileext = ".json")
    old <- options(GiottoLens.preferences_file = f)
    withr::defer({ options(old); unlink(f) }, envir = env)
    f
}

test_that("preferences take the built-in default unless set, and only set ones are saved", {
    f <- local_pref_file()
    p <- lens_preferences()
    expect_identical(p$seq_palette, "viridis")
    expect_length(attr(p, "set"), 0L)
    expect_false(file.exists(f))

    lens_preferences(seq_palette = "magma", background = "#1F2937",
        outline_width = 2, tx_palette = "vivid")
    saved <- jsonlite::read_json(f)
    expect_identical(sort(names(saved$set)), c("background", "outline_width", "seq_palette",
        "tx_palette"))
    p <- lens_preferences()
    expect_identical(p$seq_palette, "magma")
    expect_identical(p$background, "#1f2937")
    expect_identical(p$cat_palette, "default")
    expect_identical(p$selection_color, "#ffdc32")
    expect_error(lens_preferences(selection_color = "yellow"), "#rrggbb")
    expect_setequal(attr(p, "set"), c("seq_palette", "background", "outline_width", "tx_palette"))

    lens_preferences(seq_palette = NULL)
    expect_identical(lens_preferences()$seq_palette, "viridis")
    lens_preferences(reset = "outline_width")
    expect_false("outline_width" %in% names(jsonlite::read_json(f)$set))
    lens_preferences(reset = TRUE)
    expect_length(jsonlite::read_json(f)$set, 0L)
})

test_that("preferences are checked", {
    local_pref_file()
    expect_error(lens_preferences(nope = 1), "no preference 'nope'")
    expect_error(lens_preferences(seq_palette = "rainbow"), "`seq_palette` must be one of")
    expect_error(lens_preferences(outline_opacity = 2), "from 0 to 1")
    expect_error(lens_preferences(threads = 2.5), "whole number")
    expect_error(lens_preferences(background = "red"), "#rrggbb")
    expect_error(lens_preferences("magma"), "name = value")
    expect_identical(lens_preferences(threads = 8)$threads, 8L)
})

test_that("an unreadable or edited file keeps the valid preferences", {
    f <- local_pref_file()
    writeLines('{"version": 1, "set": {"seq_palette": "magma", "threads": "many", "old": 1}}', f)
    p <- lens_preferences()
    expect_identical(p$seq_palette, "magma")
    expect_identical(p$threads, 4L)
    expect_identical(attr(p, "set"), "seq_palette")
    writeLines("not json", f)
    expect_identical(lens_preferences()$seq_palette, "viridis")
})

test_that("preferences set R defaults", {
    local_pref_file()
    expect_identical(.lens_pref("threads"), 4L)
    lens_preferences(threads = 6, network_dir = "/tmp/lens-nets", history = 3)
    expect_identical(formals(LensViewer$public_methods$analysis)$threads, quote(.lens_pref("threads")))
    expect_identical(eval(formals(LensViewer$public_methods$analysis)$threads), 6L)
    withr::local_options(GiottoLens.network_dir = NULL)
    expect_identical(.default_network_dir(), "/tmp/lens-nets")
    withr::local_options(GiottoLens.network_dir = "/tmp/other")
    expect_identical(.default_network_dir(), "/tmp/other")
    msg <- .lens_pref_msg()
    expect_identical(msg$defaults$threads, 4L)
    expect_identical(msg$set$threads, 6L)
    expect_match(.encode_ws_message("preferences", msg), '"set":\\{"threads":6')
})

test_that("the viewer's Preferences panel sets and clears preferences", {
    local_pref_file()
    .lens_pref_from_viewer(list(set = list(outline_color = "#00ff00", seq_palette = "plasma")))
    p <- lens_preferences()
    expect_identical(p$outline_color, "#00ff00")
    expect_identical(p$seq_palette, "plasma")
    .lens_pref_from_viewer(list(reset = list("seq_palette")))
    expect_identical(lens_preferences()$seq_palette, "viridis")
    .lens_pref_from_viewer(list(reset = TRUE))
    expect_length(attr(lens_preferences(), "set"), 0L)
})

test_that("a page gets the preferences on connect and after a change", {
    local_pref_file()
    fx <- lens_fixture()
    skip_if_not_installed("websocket")
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    cl <- ws_client(ws_url(v))
    on.exit(cl$ws$close(), add = TRUE, after = FALSE)
    of <- function(type) Filter(function(m) identical(m$type, type), cl$state$msgs)
    expect_true(pump_until(function() length(of("preferences")) > 0L, 10))
    types <- vapply(cl$state$msgs, `[[`, "", "type")
    expect_lt(match("preferences", types), match("restore", types))
    cl$ws$send('{"type":"preferences_set","data":{"set":{"cat_palette":"vivid"}}}')
    expect_true(pump_until(function() length(of("preferences")) > 1L, 10))
    expect_identical(utils::tail(of("preferences"), 1L)[[1L]]$data$set$cat_palette, "vivid")
    expect_identical(lens_preferences()$cat_palette, "vivid")
})

test_that("the viewer's built-in preferences match R's", {
    src <- testthat::test_path("..", "..", "inst", "viewer-src", "core", "prefs.ts")
    skip_if_not(file.exists(src), "viewer source not present")
    js <- paste(readLines(src), collapse = " ")
    b <- regmatches(js, regexpr("export const BUILTIN: Prefs = [{].*?[}];", js, perl = TRUE))
    for (k in names(.lens_pref_spec())) {
        v <- .lens_pref_spec()[[k]]$default
        want <- if (is.list(v)) paste0(k, ": [{][}]")
            else if (is.character(v)) paste0(k, ": '", v, "'")
            else paste0(k, ": ", v, "[,} ]")
        expect_match(b, want, info = k)
    }
})

test_that("the tools bar's Preferences dialog shows and sets preferences in the page", {
    local_pref_file()
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() v$connected(), 30))
    # A gear in the tools bar opens it over the page; it is not a panel
    expect_false("preferences" %in% v$panels()$id)
    gear <- "document.querySelector('[data-panel=tools] [data-act=preferences]')"
    expect_true(browser_wait(br, sprintf("!!%s", gear), 30))
    br$js(sprintf("%s.click()", gear))
    expect_true(browser_wait(br, "!!document.querySelector('.start-overlay .pref-dialog .pref-panel')", 30))
    expect_true(br$js(sprintf("%s.classList.contains('active')", gear)))
    br$js("(() => { const d = document.querySelector('.pref-dialog details[data-section=\"Colors/Categories\"]');
        d.open = true; })()")
    br$js("(() => { const s = document.querySelector('[data-pref=cat_palette] select'); s.value = 'okabe_ito';
        s.dispatchEvent(new Event('change')); })()")
    expect_true(pump_until(function() identical(lens_preferences()$cat_palette, "okabe_ito"), 10))
    expect_true(browser_wait(br,
        "document.querySelector('[data-pref=cat_palette]').classList.contains('pref-set')", 10))
    # Escape closes it
    br$js("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))")
    expect_true(browser_wait(br, "!document.querySelector('.start-overlay')", 10))
    expect_false(br$js(sprintf("%s.classList.contains('active')", gear)))
    lens_preferences(outline_color = "#ff8000")
    expect_true(browser_wait(br,
        "JSON.stringify(window.__giottolens.store.getState().outline.color) === '[255,128,0]'", 10))
    v$set_outline(color = "#00ff00")
    lens_preferences(outline_color = "#0000ff")
    pump_until(function() FALSE, 1)
    expect_identical(br$js("JSON.stringify(window.__giottolens.store.getState().outline.color)"),
        "[0,255,0]")

    # The selection color follows its preference until set in the viewer;
    # set_selection_color() with no color goes back to the preference
    sel <- function() unlist(v$state()$config$selectionColor)
    lens_preferences(selection_color = "#00e5ff")
    expect_true(browser_wait(br,
        "JSON.stringify(window.__giottolens.store.getState().selectionColor) === '[0,229,255]'", 10))
    v$set_selection_color("red")
    lens_preferences(selection_color = "#ffffff")
    pump_until(function() FALSE, 1)
    expect_identical(sel(), c(255L, 0L, 0L))
    v$set_selection_color()
    expect_identical(sel(), c(255L, 255L, 255L))
    expect_length(br$errors(), 0L)
})
