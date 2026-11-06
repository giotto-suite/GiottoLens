# ── Images ───────────────────────────────────────────────────────────────────
#
# The viewer reads each image's TIFF file itself (geotiff in the browser, Viv
# layers), one file per image, served whole or by Range at image/<k>. R only
# says where the file is and where it sits in data coordinates (adr/0008).
# A file the viewer cannot read is converted once to a tiled pyramidal TIFF
# in the image cache and that copy is served (adr/0014).

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

# Manifest entries and the files behind them: the object's `images`, then
# `image_files` (named paths), which have no place in data coordinates yet and
# are drawn inside the data's extent (`place = "fit"`). Images without a file
# or whose file is a VRT are skipped with a message; other files the viewer
# cannot read are served as their cached conversion. Returns
# list(entries = manifest entries, files = k -> served path,
#      sources = name -> the image's own file).
.image_entries <- function(images, image_files = character(), cache = .image_cache()) {
    entries <- list()
    files   <- list()
    sources <- character()
    add <- function(nm, path, extent, affine = NULL, place = NULL) {
        why <- if (!length(path) || is.na(path) || !nzchar(path)) "it has no file"
               else if (!file.exists(path)) paste0("'", path, "' does not exist")
               else if (grepl("\\.vrt$", path, ignore.case = TRUE)) paste0("'", path, "' is a VRT")
        if (is.null(why)) {
            served <- tryCatch(.viewable_file(path, nm, cache), error = function(e) {
                why <<- conditionMessage(e)
                NULL
            })
        }
        if (!is.null(why)) {
            message("[launch_lens] image '", nm, "' is not shown: ", why)
            return(invisible())
        }
        if (is.null(extent)) {
            info <- .tiff_info(served)
            extent <- c(0, info$width, -info$height, 0)
        }
        k <- as.character(length(files))
        files[[k]] <<- normalizePath(served)
        sources[[nm]] <<- normalizePath(path)
        entry <- list(
            name   = nm,
            url    = paste0("image/", k),
            bytes  = file.size(served),
            # The whole image spans this box; row 0 is at ymax
            extent = list(xmin = extent[[1L]], xmax = extent[[2L]],
                          ymin = extent[[3L]], ymax = extent[[4L]])
        )
        entry$affine <- affine
        entry$place  <- place
        entries[[length(entries) + 1L]] <<- entry
    }
    for (nm in names(images)) {
        img <- images[[nm]]
        add(nm, if (methods::.hasSlot(img, "file_path")) .image_source(img),
            as.vector(terra::ext(img@raster_object)),  # xmin, xmax, ymin, ymax
            affine = .image_affine(img))
    }
    for (nm in names(image_files)) add(nm, image_files[[nm]], NULL, place = "fit")
    list(entries = entries, files = files, sources = sources)
}

# `image_files` of launch_lens(): named after the files when unnamed; names
# must not repeat or match the object's images
.check_image_files <- function(image_files, taken = character()) {
    if (is.null(image_files) || !length(image_files)) return(character())
    if (!is.character(image_files))
        stop("[launch_lens] `image_files` must be file paths", call. = FALSE)
    nms <- names(image_files) %||% rep("", length(image_files))
    unnamed <- !nzchar(nms)
    nms[unnamed] <- sub("\\.(ome\\.)?[^.]+$", "", basename(image_files[unnamed]))
    dup <- unique(nms[duplicated(nms) | nms %in% taken])
    if (length(dup))
        stop("[launch_lens] image names must be unique: ", paste(dup, collapse = ", "), call. = FALSE)
    missing <- !file.exists(image_files)
    if (any(missing))
        stop("[launch_lens] image file(s) not found: ", paste(image_files[missing], collapse = ", "),
            call. = FALSE)
    stats::setNames(as.character(image_files), nms)
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

# ── TIFF layout ──────────────────────────────────────────────────────────────
#
# What the viewer can read (data/images.ts imageKind(), layoutProblem(),
# reducedLevels()): page 1 with one sample of a supported type, or 3 or 4
# 8-bit samples in RGB or YCbCr, interleaved; above 4096 px a side, tiles and
# reduced levels (SubIFDs, or IFDs with NewSubfileType 1) that each halve the
# one above with the same tile width.

.TIFF_MAX_WHOLE <- 4096
.TIFF_TYPES <- c("1:8", "1:16", "1:32", "2:8", "2:16", "2:32", "3:32")

# Tags of the IFD at `offset`
.tiff_ifd <- function(con, offset, big, endian) {
    seek(con, offset)
    int <- function(size) {
        v <- readBin(con, "raw", size)
        if (endian == "big") v <- rev(v)
        sum(as.numeric(v) * 256^(seq_along(v) - 1L))
    }
    n <- int(if (big) 8L else 2L)
    sizes <- c(`1` = 1, `2` = 1, `3` = 2, `4` = 4, `5` = 8, `6` = 1, `7` = 1, `8` = 2,
               `9` = 4, `10` = 8, `11` = 4, `12` = 8, `13` = 4, `16` = 8, `17` = 8, `18` = 8)
    slot <- if (big) 8L else 4L
    raw_entries <- lapply(seq_len(n), function(i) list(tag = int(2L), type = int(2L),
        count = int(if (big) 8L else 4L), at = seek(con), skip = readBin(con, "raw", slot)))
    nxt <- int(slot)
    want <- c(254, 256, 257, 258, 262, 277, 284, 322, 323, 330, 339)
    tags <- list()
    for (e in raw_entries) {
        if (!e$tag %in% want) next
        size <- sizes[[as.character(e$type)]] %||% 1
        if (!size %in% c(1, 2, 4, 8) || e$type %in% c(5, 10, 11, 12)) next
        seek(con, if (e$count * size <= slot) e$at else { seek(con, e$at); int(slot) })
        tags[[as.character(e$tag)]] <- vapply(seq_len(min(e$count, 4096)), function(j) int(size), 0)
    }
    list(tags = tags, next_ifd = nxt)
}

# Size, sample layout and pyramid of a TIFF's first page; NULL for a file
# that is not a TIFF
.tiff_info <- function(path) {
    con <- file(path, "rb")
    on.exit(close(con), add = TRUE)
    head <- readBin(con, "raw", 4L)
    endian <- if (identical(head[1:2], as.raw(c(0x49, 0x49)))) "little"
              else if (identical(head[1:2], as.raw(c(0x4d, 0x4d)))) "big"
    if (is.null(endian)) return(NULL)
    ver <- if (endian == "little") as.integer(head[3]) else as.integer(head[4])
    if (!ver %in% c(42L, 43L)) return(NULL)
    big <- ver == 43L
    seek(con, if (big) 8 else 4)
    v <- readBin(con, "raw", if (big) 8L else 4L)
    if (endian == "big") v <- rev(v)
    first <- sum(as.numeric(v) * 256^(seq_along(v) - 1L))
    ifd <- function(off) .tiff_ifd(con, off, big, endian)
    tag <- function(t, k, default = NA_real_) t[[as.character(k)]][1L] %||% default
    base <- ifd(first)
    t <- base$tags
    page <- function(t) list(width = tag(t, 256), height = tag(t, 257), tile = tag(t, 322))
    candidates <- if (length(t[["330"]])) lapply(t[["330"]], function(o) page(ifd(o)$tags)) else {
        out <- list()
        nxt <- base$next_ifd
        while (nxt > 0 && length(out) < 64L) {
            i <- ifd(nxt)
            if (tag(i$tags, 254, 0) != 1) break
            out[[length(out) + 1L]] <- page(i$tags)
            nxt <- i$next_ifd
        }
        out
    }
    p <- page(t)
    levels <- 1L
    prev <- p
    for (c in candidates) {
        halves <- abs(c$width - prev$width / 2) <= 1 && abs(c$height - prev$height / 2) <= 1
        if (!halves || !identical(c$tile, p$tile)) break
        levels <- levels + 1L
        prev <- c
    }
    list(width = p$width, height = p$height, tiled = !is.na(p$tile), levels = levels,
         samples = tag(t, 277, 1), bits = tag(t, 258), format = tag(t, 339, 1),
         photometric = tag(t, 262), planar = tag(t, 284, 1))
}

# Why the viewer cannot read the file, or NULL
.tiff_problem <- function(path) {
    info <- .tiff_info(path)
    if (is.null(info)) return("not a TIFF file")
    rgb <- info$samples %in% c(3, 4) && info$photometric %in% c(2, 6)
    if (info$samples == 1) {
        if (identical(info$photometric, 3)) return("palette colours")
        if (!paste0(info$format, ":", info$bits) %in% .TIFF_TYPES)
            return(paste0(info$bits, "-bit pixels"))
    } else if (!rgb) {
        return(paste(info$samples, "samples per pixel that are not RGB"))
    } else if (info$bits != 8) {
        return(paste0(info$bits, "-bit RGB"))
    }
    if (info$samples > 1 && info$planar == 2) return("planar (not interleaved) samples")
    if (max(info$width, info$height) > .TIFF_MAX_WHOLE) {
        if (!info$tiled) return("strips, not tiles")
        if (info$levels < 2L) return("no pyramid whose levels halve")
    }
    NULL
}

# Where converted images are kept: option GiottoLens.image_cache, else the
# user cache directory
.image_cache <- function() {
    getOption("GiottoLens.image_cache", tools::R_user_dir("GiottoLens", "cache"))
}

# The file the viewer reads for `path`: the file itself, or its conversion to
# a tiled pyramidal TIFF (Cloud Optimized GeoTIFF) in `cache`, made once per
# path, size and modification time
.viewable_file <- function(path, name, cache = .image_cache()) {
    problem <- .tiff_problem(path)
    if (is.null(problem)) return(path)
    fi <- file.info(path)
    key <- paste(normalizePath(path), fi$size, as.numeric(fi$mtime))
    kf <- tempfile()
    on.exit(unlink(kf), add = TRUE)
    writeLines(key, kf)
    out <- file.path(cache, paste0(unname(tools::md5sum(kf)), ".tif"))
    if (file.exists(out)) return(out)
    dir.create(cache, recursive = TRUE, showWarnings = FALSE)
    message("[launch_lens] image '", name, "': ", problem, "; converting it to a tiled ",
        "pyramidal TIFF in ", cache)
    r <- terra::rast(path)
    tmp <- paste0(out, ".part")
    on.exit(unlink(tmp), add = TRUE)
    terra::writeRaster(r, tmp, filetype = "COG", overwrite = TRUE,
        datatype = terra::datatype(r)[[1L]],
        gdal = c("COMPRESS=DEFLATE", "BLOCKSIZE=512", "BIGTIFF=IF_SAFER",
                 "OVERVIEW_RESAMPLING=AVERAGE"))
    again <- .tiff_problem(tmp)
    if (!is.null(again))
        stop("its conversion still has ", again, call. = FALSE)
    file.rename(tmp, out)
    out
}
