# ── Images ───────────────────────────────────────────────────────────────────
#
# The viewer reads each image's TIFF file itself (geotiff in the browser, Viv
# layers), one file per image, served whole or by Range at image/<k>. R only
# says where the file is and where it sits in data coordinates (adr/0008).

# The file the viewer reads for an image. This is the one place that decides
# it; everything downstream takes the path it returns.
.image_source <- function(img) img@file_path

# Images to show: `images` is NULL (all of the object's), FALSE or an empty
# vector (none), or image names.
.pick_images <- function(x, images) {
    if (!inherits(x, "giotto") || isFALSE(images)) return(list())
    all <- x@images
    if (is.null(images)) return(all)
    images <- as.character(images)
    missing <- setdiff(images, names(all))
    if (length(missing))
        stop(sprintf("[launch_lens] image(s) not found: %s; available: %s",
            paste(missing, collapse = ", "),
            if (length(all)) paste(names(all), collapse = ", ") else "none"),
            call. = FALSE)
    all[images]
}

# Manifest entries and the files behind them. Images whose source is not a
# TIFF file (in memory, a VRT, a PNG) are skipped with a message. Returns
# list(entries = list of manifest entries, files = named list k -> path).
.image_entries <- function(images) {
    entries <- list()
    files   <- list()
    for (nm in names(images)) {
        img  <- images[[nm]]
        path <- if (methods::.hasSlot(img, "file_path")) .image_source(img)
        why  <- if (!length(path) || is.na(path) || !nzchar(path)) "it has no file"
                else if (!file.exists(path)) paste0("'", path, "' does not exist")
                else if (!.is_tiff(path)) paste0("'", path, "' is not a TIFF file")
        if (!is.null(why)) {
            message("[launch_lens] image '", nm, "' is not shown: ", why)
            next
        }
        k   <- as.character(length(files))
        ext <- as.vector(terra::ext(img@raster_object))  # xmin, xmax, ymin, ymax
        files[[k]] <- normalizePath(path)
        entry <- list(
            name   = nm,
            url    = paste0("image/", k),
            bytes  = file.size(path),
            # The whole image spans this box; row 0 is at ymax
            extent = list(xmin = ext[[1L]], xmax = ext[[2L]],
                          ymin = ext[[3L]], ymax = ext[[4L]])
        )
        entry$affine <- .image_affine(img)
        entries[[length(entries) + 1L]] <- entry
    }
    list(entries = entries, files = files)
}

# A giottoAffineImage (flipped, rotated, registered) keeps its file and
# raster as they were and the transform in @affine, applied to coordinates in
# the raster's extent as `xy %*% L + shift`. Returned as the rows of the
# column-vector form, c(a, b, c, d, e, f) for x' = a x + b y + c and
# y' = d x + e y + f; NULL for an untransformed image.
.image_affine <- function(img) {
    if (!methods::.hasSlot(img, "affine")) return(NULL)
    m <- img@affine[]
    L <- m[1:2, 1:2]
    s <- m[1:2, 3]
    if (identical(unname(L), diag(2)) && all(s == 0)) return(NULL)
    c(L[1L, 1L], L[2L, 1L], s[[1L]], L[1L, 2L], L[2L, 2L], s[[2L]])
}

.is_tiff <- function(path) {
    con <- file(path, "rb")
    on.exit(close(con), add = TRUE)
    magic <- readBin(con, "raw", 4L)
    # Little- and big-endian TIFF and BigTIFF
    any(vapply(list(c(0x49, 0x49, 0x2a, 0x00), c(0x4d, 0x4d, 0x00, 0x2a),
                    c(0x49, 0x49, 0x2b, 0x00), c(0x4d, 0x4d, 0x00, 0x2b)),
        function(m) identical(magic, as.raw(m)), logical(1L)))
}
