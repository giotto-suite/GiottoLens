# ── Launch inputs and deprecation ────────────────────────────────────────────

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

test_that("layer launches are deprecated, once per session", {
    fx <- lens_fixture()
    .lens_warned$layers <- NULL
    on.exit(.lens_warned$layers <- TRUE, add = TRUE)
    expect_warning(.resolve_object(fx$gpoints, fx$gpolygons), "deprecated")
    expect_no_warning(.resolve_object(fx$gpoints, fx$gpolygons))
})

test_that("a viewer starts without an object and refuses what needs one", {
    v <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    m <- jsonlite::fromJSON(rawToChar(http_get(lens_data_url(v, "session/manifest.json"))$content))
    expect_true(m$empty)
    expect_identical(m$load, 1L)
    expect_error(v$push_metadata(data.frame(cell_ID = "a", x = 1)), "no object loaded")
    expect_error(v$select(lens_range("x", 0, 1)), "no object loaded")
    expect_error(v$state(), "no object loaded")
    expect_output(print(v), "object: +none")
})

# ── Serving ──────────────────────────────────────────────────────────────────

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

    man <- http_get(lens_data_url(v, "session/manifest.json"))
    expect_identical(man$status_code, 200L)
    m <- jsonlite::fromJSON(rawToChar(man$content), simplifyVector = FALSE)
    tile <- m$layers$transcripts$tiles[[1]]

    part <- http_get(lens_data_url(v, tile$url), list(Range = "bytes=0-3"))
    expect_identical(part$status_code, 206L)
    expect_identical(rawToChar(part$content), "PAR1")
    expect_identical(part$headers_list[["content-range"]], sprintf("bytes 0-3/%d", tile$bytes))

    whole <- http_get(lens_data_url(v, tile$url))
    expect_identical(whole$status_code, 200L)
    expect_length(whole$content, tile$bytes)

    # The same file whole from httpuv's static thread (no R callback)
    expect_match(tile$file, "^files/transcripts/")
    static <- http_get(lens_data_url(v, tile$file))
    expect_identical(static$status_code, 200L)
    expect_identical(static$content, whole$content)
    expect_identical(m$transfer, "auto")

    expect_identical(http_get(lens_data_url(v, "data/transcripts/../x"))$status_code, 404L)

    # Nothing is served without this launch's token in the path, nor data
    # without the data secret (adr/0028); the other forms of a wrong path are
    # in test-server.R, on the app
    other <- sub("/lens/[^/]+/", "/lens/AAAAAAAAAAAAAAAAAAAAAAAA/", v$url)
    data <- sub(v$url, "", lens_data_url(v), fixed = TRUE)
    for (p in c("", paste0(data, c("session/manifest.json", tile$url, tile$file))))
        expect_identical(http_get(paste0(other, p))$status_code, 404L, info = p)
    expect_identical(http_get(paste0(base, "/other"))$status_code, 404L)
    for (p in c("session/manifest.json", tile$url, tile$file))
        expect_identical(http_get(paste0(v$url, "d/AAAAAAAAAAAAAAAAAAAAAAAA/", p))$status_code,
            404L, info = p)
})

# ── Connect and protocol on a live socket ────────────────────────────────────

# Parsing, mask decoding and annotation rows are in test-protocol.R; this is
# what only a live socket shows: the gate, the connect order, r_seq and on()
test_that("WebSocket needs the token, rejects foreign origins, and tracks its window", {
    skip_if_not_installed("websocket")
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)

    bad <- ws_client(ws_url(v, token = "wrong"), allow = FALSE)
    expect_true(pump_until(function() bad$state$closed))
    evil <- ws_client(ws_url(v), origin = "https://evil.example.com", allow = FALSE)
    expect_true(pump_until(function() evil$state$closed))
    expect_false(v$connected())

    # Metadata pushed before any tab connects is written and sent on connect,
    # after the preferences and the (empty) saved config
    v$push_metadata(fx$meta)
    a <- ws_client(ws_url(v), origin = sub("/lens/.*$", "", v$url))
    expect_true(pump_until(function() length(a$state$msgs) > 2))
    expect_identical(a$state$msgs[[1]]$type, "preferences")
    expect_identical(a$state$msgs[[2]]$type, "restore")
    expect_null(a$state$msgs[[2]]$data$config)
    expect_identical(a$state$msgs[[3]]$type, "load_metadata")
    expect_true(pump_until(function() length(a$state$msgs) > 3))
    # No rules to re-send: R's rule count alone, so the tab can report it
    expect_identical(a$state$msgs[[4]]$type, "rule_seq")
    expect_identical(a$state$msgs[[4]]$data$seq, 0L)
    expect_true(v$connected())

    ids <- lens_priv(v)$cell_ids
    got <- NULL
    v$on("annotations_update", function(d) got <<- d)
    expect_error(v$on("bogus", identity), "must be one of")
    a$ws$send('{"type":"annotations_update","data":{"annotations":[{"name":"q","geojson":"{}"}]}}')
    expect_true(pump_until(function() !is.null(got)))
    # The page's names are taken
    sq <- "POLYGON((0 0,1 0,1 1,0 1,0 0))"
    expect_error(v$push_polygons(sq, names = "q"), "must be unique; taken or repeated: q")
    expect_error(v$push_polygons(c(sq, sq), names = c("r", "r")), "repeated: r")

    expect_warning(v$set_selection(c("cell_010", "nope")), "1 ID")
    expect_identical(v$selection, "cell_010")
    expect_true(pump_until(function() length(ws_msgs(a, "set_rule")) > 0L))
    sent <- ws_msgs(a, "set_rule")[[1]]$data
    expect_identical(sent$rule$kind, "ids")
    expect_identical(sent$combine, "or")
    expect_identical(ids[.decode_mask(sent$rule$params$mask, length(ids))], "cell_010")

    # A selection the page made before R's latest rules reached it is dropped;
    # one that reflects them (or one without r_seq) is taken
    sel_msg <- function(id, seq) sprintf('{"type":"cell_selection","data":{"mask":"%s","rules":[]%s}}',
        .encode_mask(match(id, ids), length(ids)), if (is.null(seq)) "" else sprintf(',"r_seq":%d', seq))
    a$ws$send(sel_msg("cell_001", sent$seq - 1L))
    pump_for(0.3)
    expect_identical(v$selection, "cell_010")
    expect_identical(v$rules()$source, "r")
    a$ws$send(sel_msg("cell_001", sent$seq))
    expect_true(pump_until(function() identical(v$selection, "cell_001")))
    a$ws$send(sel_msg("cell_002", NULL))
    expect_true(pump_until(function() identical(v$selection, "cell_002")))

    a$ws$close()
    expect_true(pump_until(function() !v$connected()))
})

# ── Config and pushed panels ─────────────────────────────────────────────────

test_that("R keeps the page's config and pushed panels for the next page", {
    skip_if_not_installed("websocket")
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)

    # Pushed with no tab open: kept, and listed
    expect_message(id <- v$push_panel(list(mark = "bar"), data = data.frame(a = 1:3)),
        "when the viewer connects")
    expect_identical(id, "panel-1")
    big <- data.frame(a = seq_len(6000L))
    expect_message(v$push_panel(list(mark = "point"), data = big, id = "big", where = "below"))
    expect_identical(v$panels()$id, c("panel-1", "big"))
    for (id in c("spatial", "tools", "scatter", "density-2", "cells", "transcripts", "register", "layers"))
        expect_error(v$push_panel(list(mark = "bar"), id = id), "built-in", info = id)
    expect_error(v$push_panel(list(mark = "bar"), id = "a b"), "letters")
    expect_error(v$push_panel(list(mark = "bar"), where = "left"), "should be one of")
    priv <- lens_priv(v)
    work <- priv$work
    expect_length(list.files(file.path(work, "panels")), 1L)

    a <- ws_client(ws_url(v))
    expect_true(pump_until(function() length(ws_msgs(a, "push_panel")) == 2L))
    pushed <- ws_msgs(a, "push_panel")
    expect_identical(vapply(pushed, function(m) m$data$id, ""), c("panel-1", "big"))
    expect_true(all(vapply(pushed, function(m) isTRUE(m$data$restore), NA)))
    expect_identical(pushed[[2]]$data$where, "below")
    expect_match(pushed[[2]]$data$data_url, "^work/panels/big_")
    expect_identical(a$state$msgs[[2]]$data$panels, list("panel-1", "big"))

    # The page's config comes back verbatim to the next page
    cfg <- '{"state":{"layers":{"poly":{"show":false,"alpha":0.3}},"images":{},"genes":[]},"version":1}'
    ws_say(a, "config", list(json = cfg))
    # Closed in the page: R drops it and its file
    a$ws$send('{"type":"panel_closed","data":{"id":"big"}}')
    expect_true(pump_until(function() identical(names(priv$pushed), "panel-1")))
    expect_length(list.files(file.path(work, "panels")), 0L)
    a$ws$close()
    expect_true(pump_until(function() !v$connected()))

    b <- ws_client(ws_url(v))
    expect_true(pump_until(function() length(b$state$msgs) > 1))
    expect_identical(b$state$msgs[[2]]$data$config, cfg)
    expect_identical(b$state$msgs[[2]]$data$panels, list("panel-1"))
    v$remove_panel("panel-1")
    expect_true(pump_until(function() length(ws_msgs(b, "remove_panel")) > 0L))
    b$ws$close()
    expect_true(pump_until(function() !v$connected()))
    expect_identical(nrow(v$panels()), 0L)
})

# ── Relaunch and close ───────────────────────────────────────────────────────

test_that("relaunching on a port closes the old viewer and close() cleans up", {
    fx <- lens_fixture()
    v1 <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    session1 <- lens_priv(v1)$session
    expect_true(file.exists(file.path(session1, "manifest.json")))
    expect_message(v2 <- launch_lens(fx$gpoints, NULL, port = v1$port, open = FALSE),
        "closing the viewer already on port")
    on.exit(v2$close(), add = TRUE)
    expect_false(dir.exists(session1))
    expect_identical(v2$port, v1$port)
    v2$close()
    expect_false(dir.exists(lens_priv(v2)$session))
})

# ── Cells from spatial locations ─────────────────────────────────────────────

# The mark inferred from the grid (squares) is checked in test-marks.R, by
# describe()
test_that("a spatial unit without polygons launches from its spatial locations, with a given mark", {
    fx <- lens_bins_fixture()
    expect_error(launch_lens(fx$g, spat_unit = "bin", open = FALSE, mark = list(shape = "star")),
        "circle")
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE,
        mark = list(shape = "circle"))
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)
    expect_setequal(priv$cell_ids, fx$xy$cell_ID)

    # The given shape over the grid's size and angle
    m <- jsonlite::fromJSON(file.path(priv$session, "manifest.json"), simplifyVector = FALSE)
    expect_false(m$layers$cells$geometry)
    expect_identical(m$layers$cells$mark$shape, "circle")
    expect_equal(m$layers$cells$mark$size, 2, tolerance = 1e-6)
    expect_equal(m$layers$cells$mark$angle, 10, tolerance = 1e-6)
    expect_null(m$layers$transcripts)

    # Metadata and R-side selection work as for polygon cells
    v$push_metadata(fx$meta[, c("cell_ID", "half")])
    v$select(lens_categories("half", "left"))
    expect_setequal(v$selection, fx$meta$cell_ID[fx$meta$half == "left"])
})

test_that("an unknown spat_unit lists units with polygons or locations", {
    fx <- lens_bins_fixture()
    expect_error(launch_lens(fx$g, spat_unit = "cell", feat_type = NULL, open = FALSE),
        "available: bin")
})

# ── Styling argument checks ──────────────────────────────────────────────────

test_that("the styling methods check their arguments before sending", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    # A call and the error it gives; the last of each method's rows passes
    # the checks and finds no viewer to send to
    cases <- list(
        list(quote(v$set_outline(width = 0)), "must be one number in \\[0.01, 20\\]"),
        list(quote(v$set_outline(width = 0.009)), "must be one number in \\[0.01, 20\\]"),
        list(quote(v$set_outline(width = c(1, 2))), "must be one number"),
        list(quote(v$set_outline(color = c("red", "blue"))), "one color name or hex string"),
        list(quote(v$set_outline(color = "notacolour")), "invalid color name"),
        list(quote(v$set_outline(alpha = 1.5)), "must be one number in \\[0, 1\\]"),
        list(quote(v$set_outline(color = "black", width = 2)), "no viewer connected"),
        list(quote(v$set_outline(width = 0.01)), "no viewer connected"),

        list(quote(v$set_selection_color(c("red", "blue"))), "one color name or hex string"),
        list(quote(v$set_selection_color(1)), "one color name or hex string"),
        list(quote(v$set_selection_color("notacolour")), "invalid color name"),
        list(quote(v$set_selection_color("red")), "no viewer connected"),
        list(quote(v$set_selection_color()), "no viewer connected"),

        list(quote(v$set_module("nope")), "one of: registration"),
        list(quote(v$set_module(c("registration", "registration"))), "one of: registration"),
        list(quote(v$set_module("registration")), "no viewer connected"),

        list(quote(v$set_theme("blue")), "must be \"dark\" or \"light\""),
        list(quote(v$set_theme(c("dark", "light"))), "must be \"dark\" or \"light\""),
        list(quote(v$set_theme("light")), "no viewer connected"),

        list(quote(v$set_color_scale(column = c("a", "b"))), "one column name"),
        list(quote(v$set_color_scale(preset = c("viridis", "magma"))), "one preset name"),
        list(quote(v$set_color_scale(colors = "red")), "2 to 9 colors"),
        list(quote(v$set_color_scale(colors = rep("red", 10))), "2 to 9 colors"),
        list(quote(v$set_color_scale(colors = c("red", "notacolour"))), "invalid color name"),
        list(quote(v$set_color_scale(reverse = NA)), "TRUE or FALSE"),
        list(quote(v$set_color_scale(style = "rainbow")), "should be one of"),
        list(quote(v$set_color_scale(midpoint = c(1, 2))), "`midpoint` must be one number"),
        list(quote(v$set_color_scale(limits = c(2, 1))), "low < high"),
        list(quote(v$set_color_scale(limits = 1)), "low < high"),
        list(quote(v$set_color_scale(preset = "viridis")), "no viewer connected"),

        list(quote(v$style_categories(column = c("a", "b"))), "one column name"),
        list(quote(v$style_categories(show = c(A = NA))), "TRUE/FALSE"),
        list(quote(v$style_categories(alpha = c(A = 2))), "must be in \\[0, 1\\]"),
        list(quote(v$style_categories(alpha = c(0.1, 0.2))), "at most one unnamed value"),
        list(quote(v$style_categories(colors = "red")), "named by category"),
        list(quote(v$style_categories(colors = c(A = "notacolour"))), "invalid color name"),
        list(quote(v$style_categories(alpha = c(0.2, A = 1))), "no viewer connected")
    )
    for (cs in cases)
        expect_error(eval(cs[[1L]]), cs[[2L]], info = deparse(cs[[1L]]))
})

# ── set_object() ─────────────────────────────────────────────────────────────

test_that("set_object() serves another object from a clean slate", {
    skip_if_not_installed("websocket")
    fx <- lens_image_fixture()
    bx <- lens_bins_fixture()
    v <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)
    manifest <- function() jsonlite::fromJSON(rawToChar(
        http_get(lens_data_url(v, "session/manifest.json"))$content), simplifyVector = FALSE)
    status <- function(u) http_get(lens_data_url(v, u))$status_code
    tile <- manifest()$layers$cells$tiles[[1]]
    expect_identical(c(status(tile$url), status(tile$file)), c(200L, 200L))

    # Added with no tab open: a tab would be asked to open it
    v$add_image(fx$image_file, name = "post")
    a <- ws_client(ws_url(v), load = 1L)
    expect_true(pump_until(function() length(a$state$msgs) > 1))
    v$push_metadata(fx$meta)
    v$select(lens_categories("leiden_clus", "a"))
    v$save_selection("s", lens_cells("cell_001"))
    expect_message(v$push_panel(list(mark = "bar"), data = data.frame(a = 1:3)), NA)
    cfg <- '{"state":{"genes":["Actb"]},"version":2}'
    annot <- '{"type":"annotations_update","data":{"annotations":[{"name":"q","geojson":"{}"}]}}'
    ws_say(a, "config", list(json = cfg))
    a$ws$send(annot)
    expect_true(pump_until(function() identical(priv$config_json, cfg) && length(v$annotations) == 1L))

    # With work on the object, nothing changes unless it is discarded
    expect_error(v$set_object(bx$g, spat_unit = "bin", feat_type = NULL),
        paste("work not saved: 1 rule, 1 annotation, 1 saved selection, 1 pushed panel, 1 added image;",
            "save it with save\\(name\\), or pass `discard = TRUE`"))
    expect_identical(manifest()$load, 1L)
    expect_identical(v$rules()$source, "r")
    expect_identical(priv$config_json, cfg)
    expect_error(v$set_object(bx$g, discard = NA), "TRUE or FALSE")

    # Another object: a new manifest and stores, the tab told to reload, and
    # nothing of the first object
    expect_no_warning(v$set_object(bx$g, spat_unit = "bin", feat_type = NULL, discard = TRUE))
    expect_true(pump_until(function() length(ws_msgs(a, "reload")) > 0L))
    expect_identical(manifest()$load, 2L)
    expect_identical(c(status(tile$url), status(tile$file)), c(404L, 404L))
    expect_identical(nrow(v$rules()), 0L)
    expect_null(priv$cached_meta)
    expect_length(priv$pushed, 0L)
    expect_null(priv$config_json)
    expect_length(v$annotations, 0L)
    expect_length(list.files(file.path(priv$work, "metadata")), 0L)
    expect_length(list.files(file.path(priv$work, "panels")), 0L)
    expect_null(v$selection)
    expect_identical(nrow(v$selections()), 0L)
    expect_length(priv$added_images, 0L)
    expect_false(file.exists(file.path(priv$session, "images_added.json")))
    expect_length(priv$routes$images, 0L)
    expect_output(print(v), "900 cells")

    # Until it reloads, what the old tab says about its object is ignored
    ws_say(a, "config", list(json = cfg))
    a$ws$send(annot)
    pump_for(0.3)
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
    expect_length(list.files(lens_priv(v)$session, "^cells-"), 1L)
})

# ── Page asks ────────────────────────────────────────────────────────────────

test_that("the cell table asks for the IDs of cell indices, and nothing else", {
    fx <- lens_bins_fixture()
    v  <- launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- lens_priv(v)
    ask <- function(cells) priv$ask(list(op = "cell_ids", cells = cells), NULL)
    expect_identical(unlist(ask(list(0, 899, 5))$data$ids), priv$cell_ids[c(1, 900, 6)])
    expect_match(ask(list(900))$error, "cell indices")
    expect_match(ask(list(-1))$error, "cell indices")
    expect_match(ask(list(1.5))$error, "cell indices")
    expect_match(ask(list("a"))$error, "cell indices")
    expect_match(ask(NULL)$error, "cell indices")
    expect_match(ask(as.list(seq_len(5001)))$error, "cell indices")
    expect_true("cell_ids" %in% .lens_object_ops)
})
