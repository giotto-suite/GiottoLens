# Human_Breast_Biomarkers_S1_Top_he_imagealignment.csv (10x): H&E pixels to
# DAPI pixels; the DAPI image (0.2125 um pixels) spans x 0..W*mu, y -H*mu..0
tenx <- matrix(c(0.009888241210118002, 1.2895672288436943, -1108.086547782943,
                 -1.2895672288436943, 0.009888241210118002, 26722.424520037363,
                 0, 0, 1), 3L, byrow = TRUE)
mu <- 0.2125
dapi <- diag(c(mu, -mu, 1))

reg_payload <- function(transform = dapi %*% tenx, n = 4L) {
    set.seed(1)
    px <- cbind(runif(n, 0, 20515), runif(n, 0, 43995))
    data <- t(transform %*% rbind(t(px), 1))[, 1:2]
    list(
        image = "he", reference = "dapi", width = 20515, height = 43995,
        base = c(1, 0, 0, 0, 1, 0),
        landmarks = c(
            lapply(seq_len(n), function(i) list(id = paste0("l", i),
                moving = as.list(px[i, ]), fixed = as.list(data[i, ]))),
            list(list(id = "open", moving = list(5, 5), fixed = NULL))),
        transform = .affine_vector(transform), fitted = TRUE, rmse = 0,
        residuals = as.list(rep(0, n)),
        reference_transform = .affine_vector(dapi)
    )
}

test_that("a registration update is parsed into pairs and matrices", {
    reg <- .parse_registration(reg_payload())
    expect_s3_class(reg, "lens_registration")
    expect_identical(reg$image, "he")
    expect_identical(nrow(reg$landmarks), 5L)
    expect_true(is.na(reg$landmarks$fixed_x[5L]))
    expect_identical(reg$landmarks$residual, c(0, 0, 0, 0, NA))
    expect_equal(registration_matrix(reg), dapi %*% tenx)
    expect_equal(registration_matrix(reg, "reference"), tenx)
    expect_null(.parse_registration(list(image = NULL)))
    none <- .parse_registration(c(list(landmarks = list(), residuals = list()),
        reg_payload()[c("image", "transform", "base")]))
    expect_identical(nrow(none$landmarks), 0L)
    expect_false(none$fitted)
    expect_output(print(reg), "4 complete of 5")

    e <- new.env()
    .handle_ws_message(e, list(type = "registration_update", data = reg_payload()))
    expect_s3_class(e$registration, "lens_registration")
})

test_that("a registration is written as Xenium Explorer CSVs and read back", {
    reg <- .parse_registration(reg_payload())
    dir <- withr::local_tempdir()
    files <- write_registration(reg, dir)
    expect_identical(basename(files), c("he_imagealignment.csv", "he_keypoints.csv"))
    expect_equal(.read_alignment(files[["alignment"]]), tenx, tolerance = 1e-12)
    kp <- utils::read.csv(files[["keypoints"]])
    expect_named(kp, c("fixedX", "fixedY", "alignmentX", "alignmentY"))
    expect_identical(nrow(kp), 4L)
    # fixed points in DAPI pixels: the 10x matrix applied to the H&E pixels
    expect_equal(unname(as.matrix(kp[, 1:2])),
        t(tenx %*% rbind(kp$alignmentX, kp$alignmentY, 1))[, 1:2], tolerance = 1e-9)
    back <- .read_keypoints(files[["keypoints"]])
    expect_length(back, 4L)
    expect_named(back[[1L]], c("moving", "fixed_ref"))

    expect_error(.read_alignment(diag(2)), "3 x 3 affine")
    expect_error(.read_keypoints(data.frame(x = 1)), "keypoints need columns")
    no_ref <- reg
    no_ref$reference_transform <- NULL
    expect_error(write_registration(no_ref, dir), "no reference image")
})

test_that("the registered image is a giottoAffineImage at the registration's place", {
    skip_if_not_installed("GiottoClass")
    file <- withr::local_tempfile(fileext = ".tif")
    r <- terra::rast(nrows = 40, ncols = 60, vals = seq_len(2400))
    terra::writeRaster(r, file, datatype = "INT2U")
    tr <- matrix(c(0.2, 0.05, 10, -0.03, 0.15, 20, 0, 0, 1), 3L, byrow = TRUE)
    img <- .registered_image(file, tr, "he")
    expect_s4_class(img, "giottoAffineImage")
    corners <- t(tr %*% rbind(c(0, 60, 0, 60), c(0, 0, 40, 40), 1))
    expect_equal(unname(as.vector(terra::ext(img))),
        c(range(corners[, 1L]), range(corners[, 2L])), tolerance = 1e-9)
    # The viewer draws it from @affine the same way
    a <- .image_affine(img)
    e <- as.vector(terra::ext(img@raster_object))
    at <- function(px) {
        xy <- c(e[[1L]] + px[[1L]] * (e[[2L]] - e[[1L]]) / 60, e[[4L]] - px[[2L]] * (e[[4L]] - e[[3L]]) / 40)
        c(sum(a[1:2] * xy) + a[[3L]], sum(a[4:5] * xy) + a[[6L]])
    }
    expect_equal(at(c(60, 40)), as.vector(tr %*% c(60, 40, 1))[1:2], tolerance = 1e-9)
})
