test_that("export_manifest writes page-relative tile URLs and sizes", {
    fx  <- lens_fixture()
    out <- file.path(tempfile("session"), "manifest.json")
    on.exit(unlink(dirname(out), recursive = TRUE), add = TRUE)
    export_manifest(fx$gpoints, fx$gpolygons, output = out)
    m <- jsonlite::fromJSON(out, simplifyVector = FALSE)

    expect_setequal(names(m$layers), c("transcripts", "cells"))
    expect_identical(m$layers$cells$id_col, "poly_ID")
    expect_true(m$layers$cells$geometry)
    expect_null(m$layers$cells$mark)
    expect_setequal(unlist(m$layers$transcripts$genes), c("Actb", "Cd3e", "Ms4a1", "Epcam"))
    # The cell layer's tiles are the polygon store, mounted as polygons/
    mount <- c(cells = "polygons", transcripts = "transcripts")
    for (layer in names(m$layers)) {
        root <- .layer_mounts(fx$gpoints, fx$gpolygons)[[mount[[layer]]]]
        for (t in m$layers[[layer]]$tiles) {
            expect_match(t$url, paste0("^data/", mount[[layer]], "/source_id=[^/]+/tile_index=[0-9]{3}/"))
            rel <- sub(paste0("^data/", mount[[layer]], "/"), "", t$url)
            expect_equal(t$bytes, file.size(file.path(root, rel)))
        }
    }
    expect_true(m$extent$xmin <= m$extent$xmax)

    # Cells: polygon tiles concatenated in manifest order
    tiles <- m$layers$cells$tiles
    offs  <- vapply(tiles, `[[`, 0, "offset")
    ns    <- vapply(tiles, `[[`, 0, "n")
    expect_identical(offs, c(0, cumsum(ns)[-length(ns)]))
    expect_identical(m$layers$cells$cells$n, 100L)
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

test_that("cells from spatial locations are chunked and carry a mark", {
    # Spread without the RNG: a low-discrepancy sequence
    n  <- 50000L
    i  <- seq_len(n)
    xy <- data.frame(cell_ID = sprintf("c%05d", i),
        x = ((i * 0.6180339887) %% 1) * 1000, y = -((i * 0.7548776662) %% 1) * 500)
    out <- file.path(tempfile("session"), "manifest.json")
    on.exit(unlink(dirname(out), recursive = TRUE), add = TRUE)
    ids <- .export_session(NULL, NULL, out, locations = list(xy = xy))
    m <- jsonlite::fromJSON(out, simplifyVector = FALSE)

    cl <- m$layers$cells
    expect_false(cl$geometry)
    expect_null(cl$tiles[[1]]$url)
    expect_identical(cl$mark$shape, "circle")
    expect_gt(cl$mark$size, 0)
    expect_identical(cl$cells$n, n)
    expect_setequal(ids, xy$cell_ID)

    # Chunks are contiguous index ranges whose bounds hold their cells
    offs <- vapply(cl$tiles, `[[`, 0, "offset")
    ns   <- vapply(cl$tiles, `[[`, 0, "n")
    expect_gt(length(cl$tiles), 1L)
    expect_identical(offs, c(0, cumsum(ns)[-length(ns)]))
    expect_identical(sum(ns), as.numeric(n))
    cells <- arrow::read_parquet(file.path(dirname(out), "cells.parquet"))
    expect_identical(cells$cell_ID, ids)
    for (t in cl$tiles) {
        rows <- t$offset + seq_len(t$n)
        cb <- unlist(t$cbounds)
        expect_true(all(cells$x[rows] >= cb[1] - 1e-3 & cells$x[rows] <= cb[2] + 1e-3))
        expect_true(all(cells$y[rows] >= cb[3] - 1e-3 & cells$y[rows] <= cb[4] + 1e-3))
    }
    # The extent covers every cell and half a mark around it
    expect_lte(m$extent$xmin, min(xy$x) - cl$mark$size / 2 + 1e-9)
})

test_that("a given mark is written for polygon cells too", {
    fx  <- lens_fixture()
    out <- file.path(tempfile("session"), "manifest.json")
    on.exit(unlink(dirname(out), recursive = TRUE), add = TRUE)
    .export_session(NULL, fx$gpolygons, out, mark = list(shape = "square"))
    m <- jsonlite::fromJSON(out, simplifyVector = FALSE)
    expect_true(m$layers$cells$geometry)
    expect_identical(m$layers$cells$mark$shape, "square")
    # The fixture's cells are 10 apart
    expect_equal(m$layers$cells$mark$size, 10, tolerance = 1e-5)
})
