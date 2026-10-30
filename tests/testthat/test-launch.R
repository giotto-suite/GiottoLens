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

    idx <- http_get(paste0(base, "/lens/"))
    expect_identical(idx$status_code, 200L)
    expect_match(rawToChar(idx$content), "<html", ignore.case = TRUE)

    man <- http_get(paste0(base, "/lens/session/manifest.json"))
    expect_identical(man$status_code, 200L)
    m <- jsonlite::fromJSON(rawToChar(man$content), simplifyVector = FALSE)
    tile <- m$layers$transcripts$tiles[[1]]

    part <- http_get(paste0(base, "/lens/", tile$url), list(Range = "bytes=0-3"))
    expect_identical(part$status_code, 206L)
    expect_identical(rawToChar(part$content), "PAR1")
    expect_identical(part$headers_list[["content-range"]], sprintf("bytes 0-3/%d", tile$bytes))

    whole <- http_get(paste0(base, "/lens/", tile$url))
    expect_identical(whole$status_code, 200L)
    expect_length(whole$content, tile$bytes)

    # The same file whole from httpuv's static thread (no R callback)
    expect_match(tile$file, "^files/transcripts/")
    static <- http_get(paste0(base, "/lens/", tile$file))
    expect_identical(static$status_code, 200L)
    expect_identical(static$content, whole$content)
    expect_identical(m$transfer, "auto")

    expect_identical(http_get(paste0(base, "/lens/data/transcripts/../x"))$status_code, 404L)
    expect_identical(http_get(paste0(base, "/other"))$status_code, 404L)
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

    # Metadata pushed before any tab connects is written and sent on connect
    v$push_metadata(fx$meta)
    a <- ws_client(ws_url(v), origin = sub("/lens/.*$", "", v$url))
    expect_true(pump_until(function() length(a$state$msgs) > 0))
    expect_identical(a$state$msgs[[1]]$type, "load_metadata")
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

    a$ws$close(); b$ws$close()
    expect_true(pump_until(function() !v$connected()))
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
    req <- list(QUERY_STRING = "token=abc", HTTP_HOST = "127.0.0.1:1",
        HTTP_ORIGIN = "https://rstudio.example.org")
    expect_false(.ws_allowed(req, "abc"))
    expect_true(.ws_allowed(req, "abc", check_origin = FALSE))
    expect_false(.ws_allowed(modifyList(req, list(QUERY_STRING = "token=x")), "abc", check_origin = FALSE))
})
