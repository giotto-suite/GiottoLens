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
    expect_identical(out$files[["0"]], normalizePath(fx$image_file))

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

    app <- .lens_app(tempdir(), tempdir(), list(m = tempdir()), "tok", list(), images = images)
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
