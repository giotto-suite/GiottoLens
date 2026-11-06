# ── Image registration (adr/0014) ────────────────────────────────────────────
#
# The viewer registers one image (moving) against the data by landmark pairs
# and sends the result as `registration_update`. Transforms are 3x3 matrices
# acting on column vectors, c(x', y', 1) = M %*% c(x, y, 1), from the moving
# image's level-0 pixels (x = column, y = row) to data coordinates.

# c(a, b, c, d, e, f) (x' = a x + b y + c, y' = d x + e y + f) as 3x3
.affine_matrix <- function(v) {
    if (is.null(v)) return(NULL)
    v <- as.numeric(unlist(v))
    if (length(v) != 6L || anyNA(v)) return(NULL)
    matrix(c(v, 0, 0, 1), 3L, byrow = TRUE)
}

.affine_vector <- function(m) as.numeric(t(m[1:2, , drop = FALSE]))

.check_affine <- function(m, arg) {
    if (!is.matrix(m) || !is.numeric(m) || !identical(dim(m), c(3L, 3L)) || anyNA(m) ||
        !isTRUE(all.equal(unname(m[3L, ]), c(0, 0, 1))))
        stop("[LensViewer] `", arg, "` must be a 3 x 3 affine matrix with last row 0, 0, 1",
            call. = FALSE)
    if (abs(det(m)) < .Machine$double.eps)
        stop("[LensViewer] `", arg, "` is singular", call. = FALSE)
    invisible(m)
}

# A `registration_update` payload as kept on LensViewer$registration
.parse_registration <- function(dat) {
    if (is.null(dat$image)) return(NULL)
    lm <- dat$landmarks %||% list()
    xy <- function(p) if (length(p) == 2L) as.numeric(unlist(p)) else c(NA_real_, NA_real_)
    pts <- function(k) matrix(as.numeric(unlist(lapply(lm, function(l) xy(l[[k]])))),
        ncol = 2L, byrow = TRUE)
    mv <- pts("moving")
    fx <- pts("fixed")
    complete <- stats::complete.cases(mv, fx)
    res <- rep(NA_real_, length(lm))
    r <- as.numeric(unlist(dat$residuals))
    if (length(r) == sum(complete)) res[complete] <- r
    landmarks <- data.frame(
        id       = vapply(lm, function(l) as.character(l$id %||% ""), ""),
        moving_x = mv[, 1L], moving_y = mv[, 2L],
        fixed_x  = fx[, 1L], fixed_y  = fx[, 2L],
        residual = res,
        stringsAsFactors = FALSE
    )
    structure(list(
        image               = as.character(dat$image),
        reference           = if (length(dat$reference)) as.character(dat$reference),
        width               = if (length(dat$width)) as.numeric(dat$width),
        height              = if (length(dat$height)) as.numeric(dat$height),
        landmarks           = landmarks,
        transform           = .affine_matrix(dat$transform),
        fitted              = isTRUE(dat$fitted),
        rmse                = if (length(dat$rmse)) as.numeric(dat$rmse) else NA_real_,
        base                = .affine_matrix(dat$base),
        reference_transform = .affine_matrix(dat$reference_transform)
    ), class = "lens_registration")
}

#' @export
print.lens_registration <- function(x, ...) {
    n <- sum(stats::complete.cases(x$landmarks[, c("moving_x", "moving_y", "fixed_x", "fixed_y")]))
    cat("GiottoLens image registration\n")
    cat(sprintf("  image      %s\n", x$image))
    cat(sprintf("  reference  %s\n", x$reference %||% "none"))
    cat(sprintf("  pairs      %d complete of %d\n", n, nrow(x$landmarks)))
    cat(sprintf("  transform  %s\n", if (x$fitted) sprintf("affine fit, RMSE %.3g", x$rmse)
        else "placement only (fewer than 3 pairs)"))
    if (!is.null(x$transform)) print(signif(x$transform, 6))
    invisible(x)
}

#' Matrix of an image registration
#'
#' @param reg A registration, `viewer$registration` (see [LensViewer]).
#' @param to `"data"` (default): from the image's pixels to data coordinates.
#'   `"reference"`: from the image's pixels to the reference image's pixels,
#'   the matrix Xenium Explorer and Xenium Ranger read as
#'   `imagealignment.csv`.
#' @return A 3 x 3 matrix acting on `c(x, y, 1)`, pixels as `x` = column and
#'   `y` = row of the full-resolution image.
#' @export
registration_matrix <- function(reg, to = c("data", "reference")) {
    to <- match.arg(to)
    .check_registration(reg)
    if (to == "data") return(reg$transform)
    if (is.null(reg$reference_transform))
        stop("[registration_matrix] the registration has no reference image", call. = FALSE)
    solve(reg$reference_transform) %*% reg$transform
}

.check_registration <- function(reg) {
    if (!inherits(reg, "lens_registration") || is.null(reg$transform))
        stop("[GiottoLens] `reg` must be a registration from viewer$registration",
            call. = FALSE)
    invisible(reg)
}

#' Write an image registration as Xenium Explorer CSV files
#'
#' Writes `<prefix>_imagealignment.csv`, the 3 x 3 matrix from the image's
#' pixels to the reference image's pixels without a header, and
#' `<prefix>_keypoints.csv` with columns `fixedX`, `fixedY` (reference image
#' pixels) and `alignmentX`, `alignmentY` (image pixels), one row per complete
#' landmark pair. Both can be loaded back with `viewer$register_image()`.
#'
#' @param reg A registration, `viewer$registration`.
#' @param dir Directory to write to (created if missing).
#' @param prefix File name prefix; default the image name.
#' @return The two file paths, invisibly.
#' @export
write_registration <- function(reg, dir = ".", prefix = reg$image) {
    m <- registration_matrix(reg, "reference")
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
    files <- c(alignment = file.path(dir, paste0(prefix, "_imagealignment.csv")),
               keypoints = file.path(dir, paste0(prefix, "_keypoints.csv")))
    utils::write.table(format(m, digits = 17L, scientific = FALSE, trim = TRUE),
        files[["alignment"]], sep = ",", quote = FALSE, row.names = FALSE, col.names = FALSE)
    lm <- reg$landmarks[stats::complete.cases(reg$landmarks[, c("moving_x", "moving_y", "fixed_x", "fixed_y")]), ]
    fixed <- solve(reg$reference_transform) %*% rbind(lm$fixed_x, lm$fixed_y, 1)
    utils::write.csv(data.frame(fixedX = fixed[1L, ], fixedY = fixed[2L, ],
        alignmentX = lm$moving_x, alignmentY = lm$moving_y),
        files[["keypoints"]], row.names = FALSE)
    invisible(files)
}

# An alignment matrix: a 3 x 3 matrix, or an imagealignment.csv
.read_alignment <- function(x) {
    if (is.character(x)) {
        if (length(x) != 1L || !file.exists(x))
            stop("[LensViewer] alignment file not found: ", x, call. = FALSE)
        rows <- strsplit(trimws(readLines(x, warn = FALSE)), ",")
        rows <- rows[lengths(rows) > 0L]
        x <- suppressWarnings(matrix(as.numeric(unlist(rows)), nrow = length(rows), byrow = TRUE))
    }
    .check_affine(x, "alignment")
}

# Keypoints: a data.frame or keypoints.csv with fixedX, fixedY (reference
# pixels), alignmentX, alignmentY (image pixels)
.read_keypoints <- function(x) {
    if (is.character(x)) {
        if (length(x) != 1L || !file.exists(x))
            stop("[LensViewer] keypoints file not found: ", x, call. = FALSE)
        x <- utils::read.csv(x)
    }
    need <- c("fixedX", "fixedY", "alignmentX", "alignmentY")
    if (!is.data.frame(x) || !all(need %in% names(x)))
        stop("[LensViewer] keypoints need columns ", paste(need, collapse = ", "), call. = FALSE)
    x <- x[stats::complete.cases(x[need]), need]
    lapply(seq_len(nrow(x)), function(i) list(
        moving = c(x$alignmentX[i], x$alignmentY[i]),
        fixed_ref = c(x$fixedX[i], x$fixedY[i])))
}

# The image in `file` placed by `transform` (pixels to data) as a
# giottoAffineImage. GiottoClass applies an image's affine to its raster
# extent coordinates as `xy %*% m[1:2, 1:2] + m[1:2, 3]`.
.registered_image <- function(file, transform, name) {
    if (!requireNamespace("GiottoClass", quietly = TRUE))
        stop("[LensViewer] registered_image() needs GiottoClass", call. = FALSE)
    img <- GiottoClass::createGiottoLargeImage(file, name = name, verbose = FALSE)
    r <- img@raster_object
    e <- as.vector(terra::ext(r))
    to_extent <- matrix(c((e[[2L]] - e[[1L]]) / terra::ncol(r), 0, e[[1L]],
                          0, -(e[[4L]] - e[[3L]]) / terra::nrow(r), e[[4L]],
                          0, 0, 1), 3L, byrow = TRUE)
    g <- transform %*% solve(to_extent)
    GiottoClass::affine(img, rbind(cbind(t(g[1:2, 1:2]), g[1:2, 3L]), c(0, 0, 1)))
}
