# A giotto object is shown from a snapshot in its project (adr/0018): the one
# it matches, a new one saved for it, or one written from memory into
# `project`.

# Skips where the installed GiottoDisk cannot tell whether a save would move
# an object's stores (GiottoDisk#162)
skip_without_contains <- function() {
    suppressPackageStartupMessages(requireNamespace("GiottoDisk"))
    testthat::skip_if_not(methods::existsMethod("sourceContains", c("gDirSource", "giotto")),
        "GiottoDisk without sourceContains(<giotto>)")
}

snaps <- function(v) {
    p <- get("private", v$.__enclos_env__)
    GiottoDisk::snapshotInfo(p$project)
}

test_that("an object must be in a project, or be given one", {
    bx <- lens_bins_fixture()
    expect_error(launch_lens(bx$mem, spat_unit = "bin", feat_type = NULL, open = FALSE),
        "not in a GiottoDisk project; pass `project`")
    expect_error(launch_lens(bx$g, spat_unit = "bin", feat_type = NULL, open = FALSE,
        project = tempfile()), "already in a project")
    busy <- tempfile("busy_")
    dir.create(busy)
    writeLines("x", file.path(busy, "notes.txt"))
    on.exit(unlink(busy, recursive = TRUE), add = TRUE)
    expect_error(launch_lens(bx$mem, spat_unit = "bin", feat_type = NULL, open = FALSE,
        project = busy), "not a GiottoDisk project")
})

test_that("an object in memory is written into `project` and kept", {
    bx <- lens_bins_fixture()
    td <- tempfile("lensproj_")
    on.exit(unlink(td, recursive = TRUE), add = TRUE)
    v <- launch_lens(bx$mem, spat_unit = "bin", feat_type = NULL, open = FALSE, project = td)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    info <- snaps(v)
    expect_identical(nrow(info), 1L)
    expect_match(info$name, "^lens_[0-9]{8}_[0-9]{6}$")
    expect_identical(info$creator, "GiottoLens")
    expect_true(info$keep)
    expect_identical(info$session, priv$session_id)
    expect_identical(priv$snapshot, info$tag)
    expect_false(grepl(priv$session_id, v$url, fixed = TRUE))
    g <- v$gobject()
    expect_identical(normalizePath(g@source@path), normalizePath(td))
    expect_length(priv$cell_ids, 900L)
    expect_output(print(v), "snapshot: +lens_")
})

test_that("an object that matches its snapshot is shown from it, without a save", {
    fx <- lens_image_fixture()
    v <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    info <- snaps(v)
    expect_identical(info$name, "fixture")
    expect_identical(priv$snapshot, info$tag)
})

test_that("a changed object gets a new snapshot, one per change", {
    skip_without_contains()
    bx <- lens_bins_fixture()
    v <- launch_lens(bx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    add <- function(g, k) suppressMessages(GiottoClass::addCellMetadata(g,
        data.frame(cell_ID = bx$xy$cell_ID, extra = k), spat_unit = "bin",
        feat_type = "rna", by_column = TRUE, column_cell_ID = "cell_ID"))
    g2 <- add(v$gobject(), 1)
    v$set_object(g2, spat_unit = "bin", feat_type = NULL)
    v$set_object(add(g2, 2), spat_unit = "bin", feat_type = NULL)
    info <- snaps(v)
    lens <- info[startsWith(info$name, "lens_"), ]
    expect_identical(nrow(lens), 2L)
    expect_false(any(lens$keep))
    expect_identical(lens$creator, c("GiottoLens", "GiottoLens"))
    expect_identical(anyDuplicated(lens$name), 0L)
    expect_identical(get("private", v$.__enclos_env__)$snapshot, utils::tail(lens$tag, 1L))
    # The latest snapshot is the one shown and loaded back
    expect_true("extra" %in% names(GiottoClass::pDataDT(v$gobject(), spat_unit = "bin")))
    # and the first, checked out by name
    v$checkout("fixture")
    expect_identical(get("private", v$.__enclos_env__)$snapshot, info$tag[info$name == "fixture"])
})

test_that("a save that would move the object's data is refused, and nothing changes", {
    skip_without_contains()
    fx <- lens_image_fixture()
    v <- launch_lens(fx$g, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    before <- priv$snapshot
    # polygons in a store outside the project, as a disk step leaves them
    g <- fx$g
    gp <- g@spatial_info$cell
    gp@spatVector <- suppressMessages(GiottoDisk::storeWrite(GiottoDisk::parquetGeomStore(),
        GiottoDisk::storeRead(gp@spatVector, output = "terra")))
    g <- GiottoClass::setGiotto(g, gp, verbose = FALSE)
    expect_error(v$set_object(g), "not saved in its project \\(polygons 'cell'\\).*saveGiotto")
    expect_identical(priv$snapshot, before)
    expect_identical(priv$load_seq, 1L)
})

test_that("an untiled store is read as one tile, up to the cap", {
    bx <- lens_bins_fixture()
    fx <- lens_fixture()
    gp <- fx$gpolygons
    gp@spatVector <- suppressMessages(GiottoDisk::storeWrite(GiottoDisk::parquetGeomStore(),
        GiottoDisk::storeRead(gp@spatVector, output = "terra")))
    st <- .store_tiles(gp@spatVector)
    expect_identical(nrow(st), 1L)
    expect_identical(st$n, 100L)
    expect_true(file.exists(file.path(gp@spatVector@path, st$file)))
    expect_silent(.check_tile_store(gp, "giottoPolygon", "polygons"))
    GiottoUtils::gwith_options(list(GiottoLens.untiled_max = 50L),
        expect_error(.check_tile_store(gp, "giottoPolygon", "polygons"),
            "untiled store of 100 geometries"))
    cells <- .build_cells(gp@spatVector)
    expect_identical(nrow(cells$table), 100L)
    expect_identical(cells$tiles$n, 100L)
})

test_that("the untiled cap is per layer kind", {
    fx <- lens_fixture()
    gp <- fx$gpolygons
    gp@spatVector <- suppressMessages(GiottoDisk::storeWrite(GiottoDisk::parquetGeomStore(),
        GiottoDisk::storeRead(gp@spatVector, output = "terra")))
    GiottoUtils::gwith_options(list(GiottoLens.untiled_max = c(points = 10)),
        expect_silent(.check_tile_store(gp, "giottoPolygon", "polygons")))
    GiottoUtils::gwith_options(list(GiottoLens.untiled_max = c(polygons = 10)),
        expect_error(.check_tile_store(gp, "giottoPolygon", "polygons"), "up to 10 "))
})
