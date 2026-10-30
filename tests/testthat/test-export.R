test_that("export_manifest writes page-relative tile URLs and sizes", {
    fx  <- lens_fixture()
    out <- file.path(tempfile("session"), "manifest.json")
    on.exit(unlink(dirname(out), recursive = TRUE), add = TRUE)
    export_manifest(fx$gpoints, fx$gpolygons, output = out)
    m <- jsonlite::fromJSON(out, simplifyVector = FALSE)

    expect_setequal(names(m$layers), c("transcripts", "polygons"))
    expect_identical(m$layers$polygons$id_col, "poly_ID")
    expect_setequal(unlist(m$layers$transcripts$genes), c("Actb", "Cd3e", "Ms4a1", "Epcam"))
    for (layer in names(m$layers)) {
        root <- .layer_mounts(fx$gpoints, fx$gpolygons)[[layer]]
        for (t in m$layers[[layer]]$tiles) {
            expect_match(t$url, paste0("^data/", layer, "/source_id=[^/]+/tile_index=[0-9]{3}/"))
            rel <- sub(paste0("^data/", layer, "/"), "", t$url)
            expect_equal(t$bytes, file.size(file.path(root, rel)))
        }
    }
    expect_true(m$extent$xmin <= m$extent$xmax)

    # Cells: polygon tiles concatenated in manifest order
    tiles <- m$layers$polygons$tiles
    offs  <- vapply(tiles, `[[`, 0, "offset")
    ns    <- vapply(tiles, `[[`, 0, "n")
    expect_identical(offs, c(0, cumsum(ns)[-length(ns)]))
    expect_identical(m$layers$polygons$cells$n, 100L)
    cells <- arrow::read_parquet(file.path(dirname(out), "cells.parquet"))
    expect_identical(nrow(cells), 100L)
    expect_setequal(cells$cell_ID, fx$meta$cell_ID)
    first <- arrow::read_parquet(file.path(
        .layer_mounts(fx$gpoints, fx$gpolygons)$polygons,
        sub("^data/polygons/", "", tiles[[2]]$url)))
    rows <- tiles[[2]]$offset + seq_len(tiles[[2]]$n)
    expect_identical(cells$cell_ID[rows], first$poly_ID)
    expect_equal(cells$x[rows], first$x_index, tolerance = 1e-5)
    cb <- unlist(tiles[[2]]$cbounds)
    expect_equal(cb, c(min(first$x_index), max(first$x_index), min(first$y_index), max(first$y_index)))
})

test_that("export_manifest needs at least one layer", {
    expect_error(export_manifest(output = tempfile()), "gpoints and/or gpolygons")
})

test_that(".tile_file finds the legacy nested layout and errors when missing", {
    root <- tempfile("store")
    on.exit(unlink(root, recursive = TRUE), add = TRUE)
    legacy <- file.path(root, "source_id=u1", "tile_index=002", "tile_index=000")
    dir.create(legacy, recursive = TRUE)
    file.create(file.path(legacy, "part-0.parquet"))
    fake <- methods::setClass("fakeStore", representation(path = "character", uid = "character"),
        where = environment())
    st <- fake(path = root, uid = "u1")
    expect_identical(.tile_file(st, 2L),
        "source_id=u1/tile_index=002/tile_index=000/part-0.parquet")
    expect_error(.tile_file(st, 3L), "no tile parquet")
})
