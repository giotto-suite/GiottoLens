test_that("valid messages parse", {
    m <- .parse_ws_message('{"type":"cell_selection","data":{"ids":["a","b"]}}')
    expect_identical(m$type, "cell_selection")
    expect_length(m$data$ids, 2L)
})

test_that("invalid frames are dropped with a warning", {
    expect_warning(expect_null(.parse_ws_message("not json")), "invalid message")
    expect_warning(expect_null(.parse_ws_message('{"type":1}')), "invalid message")
    expect_warning(expect_null(.parse_ws_message('{"type":["a","b"]}')), "invalid message")
    expect_warning(expect_null(.parse_ws_message('{"type":"nope"}')), "invalid message")
    expect_warning(expect_null(.parse_ws_message('[1,2]')), "invalid message")
})

test_that("selection masks round-trip and match the JS bit order", {
    # JS: bits 0, 9, 12 of 13 → bytes 0b00000001, 0b00010010
    expect_identical(.encode_mask(c(1L, 10L, 13L), 13), jsonlite::base64_enc(as.raw(c(0x01, 0x12))))
    expect_identical(.decode_mask(.encode_mask(c(1L, 10L, 13L), 13), 13), c(1L, 10L, 13L))
    expect_identical(.decode_mask("", 13), integer(0))
    expect_error(.decode_mask(.encode_mask(1L, 8), 20), "shorter")
})

test_that("cell_selection resolves the mask to cell IDs and keeps the rules", {
    v <- new.env()
    ids <- c("a", "b", "c", "d")
    .handle_ws_message(v, list(type = "cell_selection", data = list(
        mask = .encode_mask(c(2L, 4L), 4), rules = list(list(kind = "polygon")))), ids)
    expect_identical(v$selection, c("b", "d"))
    expect_identical(v$selection_rules[[1]]$kind, "polygon")
    .handle_ws_message(v, list(type = "cell_selection", data = list(mask = "")), ids)
    expect_identical(v$selection, character(0))
})

test_that("annotations_update fills missing fields", {
    v <- new.env()
    .handle_ws_message(v, list(type = "annotations_update", data = list(annotations = list(
        list(id = "x", type = "polygon", geojson = "{}")
    ))))
    expect_identical(v$annotations[[1]]$name, "")
    expect_identical(v$annotations[[1]]$id, "x")
})

test_that("outbound messages keep full coordinate precision", {
    js <- .encode_ws_message("push_polygons", list(v = 1234.56789012))
    expect_match(js, "1234.56789012", fixed = TRUE)
})

test_that(".spec_take_data handles inline values and a single named dataset", {
    a <- .spec_take_data(list(mark = "bar", data = list(values = data.frame(x = 1:2))))
    expect_null(a$spec$data)
    expect_identical(nrow(a$rows), 2L)
    b <- .spec_take_data(list(datasets = list(d1 = data.frame(x = 1)),
        layer = list(list(data = list(name = "d1"), mark = "point"))))
    expect_null(b$spec$datasets)
    expect_identical(b$spec$layer[[1]]$data, list(name = "cells"))
    expect_error(.spec_take_data(list(datasets = list(a = 1, b = 2))), "more than one dataset")
})
