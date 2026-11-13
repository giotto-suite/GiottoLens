test_that("launch inputs are checked up front", {
    expect_error(.resolve_layers(NULL, NULL, "rna", "cell"), "nothing to show")
    expect_error(.resolve_layers(data.frame(), NULL, "rna", "cell"), "must be a giottoPoints")
    skip_if_not_installed("GiottoClass")
    mem <- GiottoClass::createGiottoPoints(
        data.frame(x = 1:3, y = 1:3, feat_ID = c("a", "b", "a")), verbose = FALSE)
    expect_error(.resolve_layers(mem, NULL, "rna", "cell"), "in memory")
    expect_error(.pick_layer(list(rna = 1), "protein", "feat_type"),
        "feat_type 'protein' not found; available: rna")
    expect_null(.pick_layer(list(rna = 1), NULL, "feat_type"))
})

test_that("the viewer serves its bundle, session files and data ranges on localhost", {
    fx <- lens_fixture()
    skip_if_not_installed("curl")
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    base <- sub("/lens/.*$", "", v$url)
    expect_match(base, "^http://127\\.0\\.0\\.1:[0-9]+$")
    expect_match(v$url, "/lens/[A-Za-z0-9]{24}/$")

    idx <- http_get(v$url)
    expect_identical(idx$status_code, 200L)
    expect_match(rawToChar(idx$content), "<html", ignore.case = TRUE)

    man <- http_get(paste0(v$url, "session/manifest.json"))
    expect_identical(man$status_code, 200L)
    m <- jsonlite::fromJSON(rawToChar(man$content), simplifyVector = FALSE)
    tile <- m$layers$transcripts$tiles[[1]]

    part <- http_get(paste0(v$url, tile$url), list(Range = "bytes=0-3"))
    expect_identical(part$status_code, 206L)
    expect_identical(rawToChar(part$content), "PAR1")
    expect_identical(part$headers_list[["content-range"]], sprintf("bytes 0-3/%d", tile$bytes))

    whole <- http_get(paste0(v$url, tile$url))
    expect_identical(whole$status_code, 200L)
    expect_length(whole$content, tile$bytes)

    # The same file whole from httpuv's static thread (no R callback)
    expect_match(tile$file, "^files/transcripts/")
    static <- http_get(paste0(v$url, tile$file))
    expect_identical(static$status_code, 200L)
    expect_identical(static$content, whole$content)
    expect_identical(m$transfer, "auto")

    expect_identical(http_get(paste0(v$url, "data/transcripts/../x"))$status_code, 404L)

    # Nothing is served without this launch's token in the path
    other <- sub("/lens/[^/]+/", "/lens/AAAAAAAAAAAAAAAAAAAAAAAA/", v$url)
    for (p in c("", "session/manifest.json", tile$url, tile$file)) {
        expect_identical(http_get(paste0(other, p))$status_code, 404L, info = p)
        expect_identical(http_get(paste0(base, "/lens/", p))$status_code, 404L, info = p)
    }
    expect_identical(http_get(paste0(base, "/other"))$status_code, 404L)
})

test_that("set_outline checks its arguments before sending", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$set_outline(width = 0), "must be one number in \\[0.01, 20\\]")
    expect_error(v$set_outline(width = 0.009), "must be one number in \\[0.01, 20\\]")
    expect_error(v$set_outline(width = c(1, 2)), "must be one number")
    expect_error(v$set_outline(color = c("red", "blue")), "one color name or hex string")
    expect_error(v$set_outline(color = "notacolour"), "invalid color name")
    expect_error(v$set_outline(alpha = 1.5), "must be one number in \\[0, 1\\]")
    expect_error(v$set_outline(color = "black", width = 2), "no viewer connected")
    expect_error(v$set_outline(width = 0.01), "no viewer connected")
})

test_that("set_theme checks its argument before sending", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$set_theme("blue"), "must be \"dark\" or \"light\"")
    expect_error(v$set_theme(c("dark", "light")), "must be \"dark\" or \"light\"")
    expect_error(v$set_theme("light"), "no viewer connected")
})

test_that("set_column_type switches numeric columns and keeps the setting", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$set_column_type("score"), "no metadata pushed yet")
    suppressMessages(v$push_metadata(fx$meta))
    priv <- v$.__enclos_env__$private
    kind <- function(name) Filter(function(cl) cl$name == name, priv$cached_meta$columns)[[1]]$kind
    expect_identical(kind("score"), "continuous")
    v$set_column_type("score", "categorical")
    expect_identical(kind("score"), "categorical")
    expect_true(is.factor(priv$meta_column("score")))
    # one file per column; the previous payload's are kept
    files <- list.files(priv$meta_dir())
    expect_true(all(basename(vapply(priv$cached_meta$columns, `[[`, "", "url")) %in% files))
    suppressMessages(v$push_metadata(fx$meta))
    expect_identical(kind("score"), "categorical")
    v$set_column_type("score", "continuous")
    expect_identical(kind("score"), "continuous")
    expect_error(v$set_column_type("leiden_clus", "continuous"), "is not numeric")
    # Text whose values are numbers goes to continuous, not the other way
    suppressMessages(v$push_metadata(data.frame(cell_ID = fx$meta$cell_ID,
        txt = as.character(seq_along(fx$meta$cell_ID)))))
    expect_true(priv$meta_entry("txt")$number_text)
    expect_error(v$set_column_type("txt", "categorical"), "is not numeric")
    v$set_column_type("txt", "continuous")
    expect_identical(kind("txt"), "continuous")
    expect_identical(priv$meta_column("txt"), as.double(match(priv$cell_ids, fx$meta$cell_ID)))
    expect_error(v$set_column_type("nope"), "no metadata column 'nope'")
    expect_error(v$set_column_type("score", "other"), "should be one of")
})

test_that("a type given to push_metadata() replaces a kept one", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- v$.__enclos_env__$private
    kind <- function(name) priv$meta_entry(name)$kind
    suppressMessages(v$push_metadata(fx$g, spat_unit = "bin"))
    expect_identical(kind("array_row"), "continuous")
    v$set_column_type("array_row", "categorical")
    suppressMessages(v$push_metadata(fx$g, spat_unit = "bin"))
    expect_identical(kind("array_row"), "categorical")
    suppressMessages(v$push_metadata(fx$g, spat_unit = "bin",
        cols = list(array_row = "continuous", "array_col")))
    expect_identical(kind("array_row"), "continuous")
    expect_null(priv$col_types$array_row)
})

test_that("set_color_scale checks its arguments before sending", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$set_color_scale(column = c("a", "b")), "one column name")
    expect_error(v$set_color_scale(preset = c("viridis", "magma")), "one preset name")
    expect_error(v$set_color_scale(colors = "red"), "2 to 9 colors")
    expect_error(v$set_color_scale(colors = rep("red", 10)), "2 to 9 colors")
    expect_error(v$set_color_scale(colors = c("red", "notacolour")), "invalid color name")
    expect_error(v$set_color_scale(reverse = NA), "TRUE or FALSE")
    expect_error(v$set_color_scale(preset = "viridis"), "no viewer connected")
})

test_that("style_categories checks its arguments before sending", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$style_categories(column = c("a", "b")), "one column name")
    expect_error(v$style_categories(show = c(A = NA)), "TRUE/FALSE")
    expect_error(v$style_categories(alpha = c(A = 2)), "must be in \\[0, 1\\]")
    expect_error(v$style_categories(alpha = c(0.1, 0.2)), "at most one unnamed value")
    expect_error(v$style_categories(colors = "red"), "named by category")
    expect_error(v$style_categories(colors = c(A = "notacolour")), "invalid color name")
    expect_error(v$style_categories(alpha = c(0.2, A = 1)), "no viewer connected")
})

test_that("WebSocket needs the token, rejects foreign origins, and tracks tabs", {
    fx <- lens_fixture()
    skip_if_not_installed("websocket")
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)

    bad <- ws_client(ws_url(v, token = "wrong"))
    expect_true(pump_until(function() bad$state$closed))
    evil <- ws_client(ws_url(v), origin = "https://evil.example.com")
    expect_true(pump_until(function() evil$state$closed))
    expect_false(v$connected())

    # Metadata pushed before any tab connects is written and sent on connect,
    # after the (empty) saved config
    v$push_metadata(fx$meta)
    a <- ws_client(ws_url(v), origin = sub("/lens/.*$", "", v$url))
    expect_true(pump_until(function() length(a$state$msgs) > 1))
    expect_identical(a$state$msgs[[1]]$type, "restore")
    expect_null(a$state$msgs[[1]]$data$config)
    expect_identical(a$state$msgs[[2]]$type, "load_metadata")
    expect_true(pump_until(function() length(a$state$msgs) > 2))
    # No rules to re-send: R's rule count alone, so the tab can report it
    expect_identical(a$state$msgs[[3]]$type, "rule_seq")
    expect_identical(a$state$msgs[[3]]$data$seq, 0L)
    expect_true(v$connected())

    ids <- get("private", v$.__enclos_env__)$cell_ids
    mask <- .encode_mask(match(c("cell_001", "cell_002"), ids), length(ids))
    a$ws$send(sprintf('{"type":"cell_selection","data":{"mask":"%s","rules":[]}}', mask))
    expect_true(pump_until(function() length(v$selection) == 2L))
    expect_setequal(v$selection, c("cell_001", "cell_002"))
    a$ws$send('{"type":1,"data":{}}')
    expect_warning(pump_until(function() FALSE, timeout = 0.3), "invalid message")

    got <- NULL
    v$on("annotations_update", function(d) got <<- d)
    expect_error(v$on("bogus", identity), "must be one of")
    a$ws$send('{"type":"annotations_update","data":{"annotations":[{"id":"q","type":"polygon","geojson":"{}"}]}}')
    expect_true(pump_until(function() !is.null(got)))
    expect_identical(v$annotations[[1]]$id, "q")

    b <- ws_client(ws_url(v))
    expect_true(pump_until(function() b$state$open))
    expect_warning(v$set_selection(c("cell_010", "nope")), "1 ID")
    expect_identical(v$selection, "cell_010")
    got_sel <- function(st) Filter(function(m) m$type == "set_rule", st$msgs)
    expect_true(pump_until(function() length(got_sel(a$state)) && length(got_sel(b$state))))
    sent <- got_sel(a$state)[[1]]$data
    expect_identical(sent$rule$kind, "ids")
    expect_identical(sent$combine, "or")
    expect_identical(ids[.decode_mask(sent$rule$params$mask, length(ids))], "cell_010")

    # A selection the page made before R's latest rules reached it is dropped;
    # one that reflects them (or one without r_seq) is taken
    sel_msg <- function(id, seq) sprintf('{"type":"cell_selection","data":{"mask":"%s","rules":[]%s}}',
        .encode_mask(match(id, ids), length(ids)), if (is.null(seq)) "" else sprintf(',"r_seq":%d', seq))
    a$ws$send(sel_msg("cell_001", sent$seq - 1L))
    pump_until(function() FALSE, timeout = 0.3)
    expect_identical(v$selection, "cell_010")
    expect_identical(v$rules()$source, "r")
    a$ws$send(sel_msg("cell_001", sent$seq))
    expect_true(pump_until(function() identical(v$selection, "cell_001")))
    a$ws$send(sel_msg("cell_002", NULL))
    expect_true(pump_until(function() identical(v$selection, "cell_002")))

    a$ws$close(); b$ws$close()
    expect_true(pump_until(function() !v$connected()))
})

test_that("R keeps the page's config and pushed panels for the next page", {
    fx <- lens_fixture()
    skip_if_not_installed("websocket")
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)

    # Pushed with no tab open: kept, and listed
    expect_message(id <- v$push_panel(list(mark = "bar"), data = data.frame(a = 1:3)),
        "when the viewer connects")
    expect_identical(id, "panel-1")
    big <- data.frame(a = seq_len(6000L))
    expect_message(v$push_panel(list(mark = "point"), data = big, id = "big", where = "below"))
    expect_identical(v$panels()$id, c("panel-1", "big"))
    for (id in c("scatter", "density-2", "cells", "transcripts", "register", "layers"))
        expect_error(v$push_panel(list(mark = "bar"), id = id), "built-in", info = id)
    expect_error(v$push_panel(list(mark = "bar"), id = "a b"), "letters")
    expect_error(v$push_panel(list(mark = "bar"), where = "left"), "should be one of")
    priv <- get("private", v$.__enclos_env__)
    session <- priv$session
    expect_length(list.files(file.path(session, "panels")), 1L)

    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() length(Filter(function(m) m$type == "push_panel", a$state$msgs)) == 2L))
    pushed <- Filter(function(m) m$type == "push_panel", a$state$msgs)
    expect_identical(vapply(pushed, function(m) m$data$id, ""), c("panel-1", "big"))
    expect_true(all(vapply(pushed, function(m) isTRUE(m$data$restore), NA)))
    expect_identical(pushed[[2]]$data$where, "below")
    expect_match(pushed[[2]]$data$data_url, "^session/panels/big_")
    expect_identical(a$state$msgs[[1]]$data$panels, list("panel-1", "big"))

    # The page's config comes back verbatim to the next page
    cfg <- '{"state":{"layers":{"poly":{"show":false,"alpha":0.3}},"images":{},"genes":[]},"version":1}'
    a$ws$send(jsonlite::toJSON(list(type = "config", data = list(json = cfg)), auto_unbox = TRUE))
    # Closed in the page: R drops it and its file
    a$ws$send('{"type":"panel_closed","data":{"id":"big"}}')
    expect_true(pump_until(function() identical(names(priv$pushed), "panel-1")))
    expect_length(list.files(file.path(session, "panels")), 0L)
    a$ws$close()
    expect_true(pump_until(function() !v$connected()))

    b <- ws_client(ws_url(v))
    expect_true(pump_until(function() length(b$state$msgs) > 0))
    expect_identical(b$state$msgs[[1]]$data$config, cfg)
    expect_identical(b$state$msgs[[1]]$data$panels, list("panel-1"))
    v$remove_panel("panel-1")
    expect_true(pump_until(function() any(vapply(b$state$msgs, function(m) m$type == "remove_panel", NA))))
    b$ws$close()
    expect_true(pump_until(function() !v$connected()))
    expect_identical(nrow(v$panels()), 0L)
})

test_that("relaunching on a port closes the old viewer and close() cleans up", {
    fx <- lens_fixture()
    v1 <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    session1 <- get("private", v1$.__enclos_env__)$session
    expect_true(file.exists(file.path(session1, "manifest.json")))
    expect_message(v2 <- launch_lens(fx$gpoints, NULL, port = v1$port, open = FALSE),
        "closing the viewer already on port")
    on.exit(v2$close(), add = TRUE)
    expect_false(dir.exists(session1))
    expect_identical(v2$port, v1$port)
    v2$close()
    expect_false(dir.exists(get("private", v2$.__enclos_env__)$session))
})

test_that("the viewer opens in RStudio's pane, else the browser", {
    opened <- NULL
    pane <- function(url) opened <<- url
    local_browse <- function(url) opened <<- paste("browser:", url)
    old <- options(browser = local_browse, GiottoLens.viewer = NULL)
    on.exit(options(old), add = TRUE)

    expect_identical(.open_viewer("u", ide = "rstudio", pane = pane), "pane")
    expect_identical(opened, "u")
    expect_identical(.open_viewer("u", ide = "rstudio-server", pane = pane), "pane")
    expect_identical(.open_viewer("u", ide = "positron", pane = pane), "browser")
    expect_identical(.open_viewer("u", ide = "none", pane = pane), "browser")
    expect_identical(.open_viewer("u", ide = "rstudio", pane = NULL), "browser")
    options(GiottoLens.viewer = "browser")
    expect_identical(.open_viewer("u", ide = "rstudio", pane = pane), "browser")
})

test_that(".ide reads the IDE from the environment", {
    old <- Sys.getenv(c("POSITRON", "RSTUDIO", "RSTUDIO_PROGRAM_MODE"), unset = NA)
    on.exit(for (k in names(old))
        if (is.na(old[[k]])) Sys.unsetenv(k) else do.call(Sys.setenv, as.list(old[k])), add = TRUE)
    Sys.unsetenv(c("POSITRON", "RSTUDIO", "RSTUDIO_PROGRAM_MODE"))
    expect_identical(.ide(), "none")
    Sys.setenv(RSTUDIO = "1", RSTUDIO_PROGRAM_MODE = "desktop")
    expect_identical(.ide(), "rstudio")
    Sys.setenv(RSTUDIO_PROGRAM_MODE = "server")
    expect_identical(.ide(), "rstudio-server")
    Sys.setenv(POSITRON = "1")
    expect_identical(.ide(), "positron")
})

test_that("without the Origin check the token alone admits a socket", {
    req <- list(PATH_INFO = "/lens/abc/ws", HTTP_HOST = "127.0.0.1:1",
        HTTP_ORIGIN = "https://rstudio.example.org")
    expect_false(.ws_allowed(req, "abc"))
    expect_true(.ws_allowed(req, "abc", check_origin = FALSE))
    expect_false(.ws_allowed(modifyList(req, list(PATH_INFO = "/lens/x/ws")), "abc", check_origin = FALSE))
})

test_that("a spatial unit without polygons launches from its spatial locations", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    expect_setequal(priv$cell_ids, fx$xy$cell_ID)

    m <- jsonlite::fromJSON(file.path(priv$session, "manifest.json"), simplifyVector = FALSE)
    expect_false(m$layers$cells$geometry)
    expect_identical(m$layers$cells$mark$shape, "square")
    expect_equal(m$layers$cells$mark$size, 2, tolerance = 1e-6)
    expect_equal(m$layers$cells$mark$angle, 10, tolerance = 1e-6)
    expect_null(m$layers$transcripts)

    # Metadata and R-side selection work as for polygon cells
    v$push_metadata(fx$meta[, c("cell_ID", "half")])
    v$select(lens_categories("half", "left"))
    expect_setequal(v$selection, fx$meta$cell_ID[fx$meta$half == "left"])
})

test_that("a given mark overrides the inferred one", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE,
        mark = list(shape = "circle"))
    on.exit(v$close(), add = TRUE)
    m <- jsonlite::fromJSON(file.path(get("private", v$.__enclos_env__)$session,
        "manifest.json"), simplifyVector = FALSE)
    expect_identical(m$layers$cells$mark$shape, "circle")
    expect_equal(m$layers$cells$mark$size, 2, tolerance = 1e-6)
    expect_error(launch_lens(fx$g, spat_unit = "bin", open = FALSE, mark = list(shape = "star")),
        "circle")
})

test_that("an unknown spat_unit lists units with polygons or locations", {
    fx <- lens_bins_fixture()
    expect_error(launch_lens(fx$g, spat_unit = "cell", feat_type = NULL, open = FALSE),
        "available: bin")
})

test_that("set_mark checks its arguments, and describe() reports the cells", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$set_mark(shape = "star"), "\\[set_mark\\] mark shape")
    expect_error(v$set_mark(size = 0), "\\[set_mark\\] mark size")
    expect_error(v$set_mark(show = NA), "\\[set_mark\\] show")
    d <- v$describe()
    expect_identical(d$cells$source, "locations")
    expect_identical(d$cells$mark$shape, "square")
    expect_output(print(d), "900 from spatial locations, drawn as squares 2 across at 10 degrees")

    fx2 <- lens_fixture()
    p <- launch_lens(fx2$gpoints, open = FALSE)
    on.exit(p$close(), add = TRUE)
    expect_error(p$set_mark(size = 1), "no cells")
    expect_null(p$describe()$cells)
})

test_that("a viewer starts without an object and refuses what needs one", {
    v <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    m <- jsonlite::fromJSON(rawToChar(http_get(paste0(v$url, "session/manifest.json"))$content))
    expect_true(m$empty)
    expect_identical(m$load, 1L)
    expect_error(v$push_metadata(data.frame(cell_ID = "a", x = 1)), "no object loaded")
    expect_error(v$select(lens_range("x", 0, 1)), "no object loaded")
    expect_error(v$state(), "no object loaded")
    expect_output(print(v), "object: +none")
})

test_that("layer launches are deprecated, once per session", {
    fx <- lens_fixture()
    .lens_warned$layers <- NULL
    on.exit(.lens_warned$layers <- TRUE, add = TRUE)
    expect_warning(.resolve_object(fx$gpoints, fx$gpolygons), "deprecated")
    expect_no_warning(.resolve_object(fx$gpoints, fx$gpolygons))
})

test_that("set_object() serves another object from a clean slate", {
    fx <- lens_image_fixture()
    bx <- lens_bins_fixture()
    skip_if_not_installed("websocket")
    v <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    manifest <- function() jsonlite::fromJSON(rawToChar(
        http_get(paste0(v$url, "session/manifest.json"))$content), simplifyVector = FALSE)
    status <- function(u) http_get(paste0(v$url, u))$status_code
    tile <- manifest()$layers$cells$tiles[[1]]
    expect_identical(c(status(tile$url), status(tile$file)), c(200L, 200L))

    a <- ws_client(ws_url(v), load = 1L)
    expect_true(pump_until(function() length(a$state$msgs) > 1))
    v$push_metadata(fx$meta)
    v$select(lens_categories("leiden_clus", "a"))
    expect_message(v$push_panel(list(mark = "bar"), data = data.frame(a = 1:3)), NA)
    cfg <- '{"state":{"genes":["Actb"]},"version":2}'
    annot <- '{"type":"annotations_update","data":{"annotations":[{"id":"q","type":"polygon","geojson":"{}"}]}}'
    a$ws$send(jsonlite::toJSON(list(type = "config", data = list(json = cfg)), auto_unbox = TRUE))
    a$ws$send(annot)
    expect_true(pump_until(function() identical(priv$config_json, cfg) && length(v$annotations) == 1L))

    # With work on the object, nothing changes unless it is discarded
    expect_error(v$set_object(bx$g, spat_unit = "bin", feat_type = NULL),
        "has 1 rule, 1 annotation, 1 pushed panel; pass `discard = TRUE`")
    expect_identical(manifest()$load, 1L)
    expect_identical(v$rules()$source, "r")
    expect_identical(priv$config_json, cfg)
    expect_error(v$set_object(bx$g, discard = NA), "TRUE or FALSE")

    # Another object: a new manifest and stores, the tab told to reload, and
    # nothing of the first object
    expect_no_warning(v$set_object(bx$g, spat_unit = "bin", feat_type = NULL, discard = TRUE))
    expect_true(pump_until(function() any(vapply(a$state$msgs, function(m) m$type == "reload", NA))))
    expect_identical(manifest()$load, 2L)
    expect_identical(c(status(tile$url), status(tile$file)), c(404L, 404L))
    expect_identical(nrow(v$rules()), 0L)
    expect_null(priv$cached_meta)
    expect_length(priv$pushed, 0L)
    expect_null(priv$config_json)
    expect_length(v$annotations, 0L)
    expect_length(list.files(file.path(priv$session, "metadata")), 0L)
    expect_length(list.files(file.path(priv$session, "panels")), 0L)
    expect_output(print(v), "900 cells")

    # Until it reloads, what the old tab says about its object is ignored
    a$ws$send(jsonlite::toJSON(list(type = "config", data = list(json = cfg)), auto_unbox = TRUE))
    a$ws$send(annot)
    pump_until(function() FALSE, timeout = 0.3)
    expect_null(priv$config_json)
    expect_length(v$annotations, 0L)
    # A tab that reconnects with the old load is told to reload
    b <- ws_client(ws_url(v), load = 1L)
    expect_true(pump_until(function() length(b$state$msgs) > 0))
    expect_identical(b$state$msgs[[1]]$type, "reload")

    # Back to the first object: served again, from a clean slate; without
    # work there is nothing to discard
    expect_no_error(v$set_object(fx$g))
    expect_identical(manifest()$load, 3L)
    expect_null(priv$config_json)
    expect_identical(nrow(v$rules()), 0L)
    expect_identical(c(status(tile$url), status(tile$file)), c(200L, 200L))
    for (cl in list(a, b)) cl$ws$close()
})

test_that("R evaluates rules on the cells of the object shown", {
    fx <- lens_image_fixture()
    bx <- lens_bins_fixture()
    v <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    box <- lens_polygon(rbind(c(0, -100), c(100, -100), c(100, 0), c(0, 0)))
    v$select(box)
    expect_length(v$selection, 100L)
    v$set_object(bx$g, spat_unit = "bin", feat_type = NULL, discard = TRUE)
    v$select(box)
    expect_length(v$selection, sum(bx$xy$sdimx >= 0 & bx$xy$sdimx <= 100 &
        bx$xy$sdimy >= -100 & bx$xy$sdimy <= 0))
    expect_true(all(startsWith(v$selection, "bin_")))
    expect_length(list.files(get("private", v$.__enclos_env__)$session, "^cells-"), 1L)
})
