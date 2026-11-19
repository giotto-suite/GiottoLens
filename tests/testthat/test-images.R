test_that("images are picked by name and need a TIFF file", {
    fx <- lens_image_fixture()
    expect_named(.pick_images(fx$g, NULL), c("stain", "he"))
    expect_named(.pick_images(fx$g, "he"), "he")
    expect_length(.pick_images(fx$g, FALSE), 0L)
    expect_length(.pick_images(fx$gpoints, NULL), 0L)
    expect_error(.pick_images(fx$g, "nope"), "not found: nope; available: stain, he")

    expect_true(.is_tiff(fx$image_file))
    vrt <- tempfile(fileext = ".vrt")
    on.exit(unlink(vrt), add = TRUE)
    writeLines("<VRTDataset/>", vrt)
    expect_false(.is_tiff(vrt))

    imgs <- .pick_images(fx$g, NULL)
    out <- .image_entries(imgs)
    expect_identical(out$entries[[1L]]$url, "image/0")
    expect_identical(out$entries[[1L]]$extent, list(xmin = 0, xmax = 100, ymin = -100, ymax = 0))
    # the object is in a project, which holds its own copy of the file
    expect_identical(out$files[["0"]], normalizePath(imgs$stain@file_path))

    # A VRT in @file_path (GiottoDisk's vault stubs) is skipped, not served
    stub <- imgs$stain
    stub@file_path <- vrt
    expect_message(out <- .image_entries(list(stub = stub)), "'stub' is not shown: .* is not a TIFF")
    expect_length(out$entries, 0L)
})

test_that("image files are served by Range at image/<k> and nothing else is", {
    fx <- lens_image_fixture()
    images <- list("0" = normalizePath(fx$image_file))
    req <- function(path, range = NULL)
        list(PATH_INFO = path, HTTP_RANGE = range, REQUEST_METHOD = "GET")
    r <- .data_response(req("/lens/tok/image/0", "bytes=0-3"), list(), "/lens/tok", images)
    expect_identical(r$status, 206L)
    expect_identical(r$body, readBin(fx$image_file, "raw", 4L))
    for (p in c("/lens/tok/image/1", "/lens/tok/image/", "/lens/tok/image/0/x",
                "/lens/tok/image/../image/0", "/lens/other/image/0"))
        expect_identical(.data_response(req(p), list(), "/lens/tok", images)$status, 404L, info = p)

    app <- .lens_app(tempdir(), tempdir(), lens_routes(list(m = tempdir()), images), "tok", list())
    expect_true(app$staticPaths[["/lens/tok/image"]]$options$exclude)
})

test_that("a transformed image carries its affine; a plain one none", {
    fx <- lens_image_fixture()
    stain <- fx$g@images$stain
    expect_null(.image_affine(stain))
    # Vertical flip about y = 0: x' = x, y' = -y
    expect_equal(.image_affine(GiottoClass::flip(stain)), c(1, 0, 0, 0, -1, 0))
    turned <- GiottoClass::spin(stain, 30)
    a <- .image_affine(turned)
    xy <- c(25, -25)
    expect_equal(c(sum(a[1:2] * xy) + a[3], sum(a[4:5] * xy) + a[6]),
        as.vector(GiottoClass:::.affine_matrix(matrix(xy, 1L), turned@affine[])))
    expect_identical(.image_entries(list(t = turned))$entries[[1L]]$affine, a)
})

test_that("a TIFF's size and pyramid are read from its header", {
    strip <- withr::local_tempfile(fileext = ".tif")
    r <- terra::rast(nrows = 300, ncols = 5000, vals = seq_len(1.5e6) %% 60000)
    terra::writeRaster(r, strip, datatype = "INT2U")
    info <- .tiff_info(strip)
    expect_identical(c(info$width, info$height, info$samples, info$bits), c(5000, 300, 1, 16))
    expect_false(info$tiled)
    expect_identical(info$levels, 1L)

    fx <- lens_image_fixture()
    cog <- .tiff_info(fx$image_file)
    expect_identical(c(cog$width, cog$height), c(1200, 1200))
    expect_true(cog$tiled)
    expect_gt(cog$levels, 1L)
})

test_that("image files are added by name and placed inside the data", {
    fx <- lens_image_fixture()
    files <- .check_image_files(fx$image_file, taken = "stain")
    expect_identical(unname(files), fx$image_file)
    expect_error(.check_image_files(c(a = fx$image_file, a = fx$image_file)), "must be unique: a")
    expect_error(.check_image_files(c(stain = fx$image_file), taken = "stain"), "must be unique: stain")
    expect_error(.check_image_files("nope.tif"), "not found: nope.tif")

    out <- .image_entries(list(), c(he2 = fx$image_file))
    e <- out$entries[[1L]]
    expect_identical(e$name, "he2")
    expect_identical(e$place, "fit")
    expect_identical(e$extent$xmin, 0)
    expect_identical(e$extent$ymax, 0)
    expect_identical(out$sources[["he2"]], normalizePath(fx$image_file))
})

test_that("add_image() serves a file and lists it for tabs that open later", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    added <- function() {
        r <- http_get(paste0(v$url, "session/images_added.json"))
        if (r$status_code == 404L) return(list())
        jsonlite::fromJSON(rawToChar(r$content), simplifyVector = FALSE)
    }
    expect_length(added(), 0L)

    v$add_image(fx$image_file, name = "post")
    e <- added()
    expect_length(e, 1L)
    expect_identical(e[[1L]]$name, "post")
    expect_identical(e[[1L]]$url, "image/0")
    expect_identical(e[[1L]]$place, "fit")
    img <- http_get(paste0(v$url, "image/0"), list(Range = "bytes=0-3"))
    expect_identical(img$status_code, 206L)
    expect_identical(http_get(paste0(v$url, "image/1"))$status_code, 404L)

    v$add_image(fx$rgb_file)
    e <- added()
    expect_identical(vapply(e, `[[`, "", "name"), c("post", sub("\\.tif$", "", basename(fx$rgb_file))))
    expect_identical(e[[2L]]$url, "image/1")

    expect_error(v$add_image(fx$image_file, name = "post"), "\\[LensViewer\\] image names must be unique: post")
    expect_error(v$add_image("nope.tif"), "\\[LensViewer\\] image file\\(s\\) not found: nope.tif")
    vrt <- tempfile(fileext = ".vrt")
    writeLines("<VRTDataset/>", vrt)
    expect_error(v$add_image(vrt), "is not a TIFF file")
    expect_error(v$add_image(c(fx$image_file, fx$rgb_file)), "must be one file path")
    expect_length(added(), 2L)
})

test_that(".choose_image_file() uses the GiottoLens.choose_file option", {
    withr::local_options(GiottoLens.choose_file = function() "/a/b.tif")
    expect_identical(.choose_image_file(), "/a/b.tif")
    withr::local_options(GiottoLens.choose_file = function() character())
    expect_null(.choose_image_file())
    withr::local_options(GiottoLens.choose_file = function() NULL)
    expect_null(.choose_image_file())
})

test_that("image keys continue after the served files", {
    fx <- lens_image_fixture()
    out <- .image_entries(list(), c(a = fx$image_file), first = 2L)
    expect_identical(out$entries[[1L]]$url, "image/2")
    expect_identical(names(out$files), "2")
    get <- function(k) .data_response(list(PATH_INFO = paste0("/lens/t/image/", k)),
        list(), "/lens/t", out$files)$status
    expect_identical(get("2"), 200L)
    expect_identical(get("0"), 404L)
})

test_that("a 10x Xenium image is read with Giotto's Xenium reader, in microns", {
    xen <- lens_xenium_fixture()
    img <- .xenium_image_file(xen$file, "dapi")
    expect_s4_class(img, "giottoLargeImage")
    expect_equal(unname(as.vector(terra::ext(img@raster_object))), c(0, 40, -50, 0))
    out <- .image_entries(list(dapi = img), first = 1L)
    e <- out$entries[[1L]]
    expect_identical(e$url, "image/1")
    expect_null(e$place)
    expect_equal(unlist(e$extent), c(xmin = 0, xmax = 40, ymin = -50, ymax = 0))
    expect_identical(out$sources[["dapi"]], normalizePath(xen$file))

    loose <- tempfile(fileext = ".tif")
    file.copy(xen$file, loose)
    expect_error(.xenium_image_file(loose, "dapi"), "no experiment.xenium in the folder of")
})

test_that("added images belong to the object shown", {
    fx <- lens_image_fixture()
    v  <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- v$.__enclos_env__$private
    v$add_image(fx$image_file, name = "post")
    expect_error(v$set_object(fx$gpoints, fx$gpolygons), "1 added image")
    v$set_object(fx$gpoints, fx$gpolygons, discard = TRUE)
    expect_length(priv$added_images, 0L)
    expect_false(file.exists(file.path(priv$session, "images_added.json")))
    expect_length(priv$routes$images, 0L)
    v$add_image(fx$image_file, name = "post")
    expect_identical(names(priv$routes$images), "0")
})
