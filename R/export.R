#' Export a GiottoLens manifest.json
#'
#' Generates the manifest JSON that tells the viewer where to find tile data.
#' Called internally by [launch_lens()]; can also be called directly if you
#' want to regenerate the manifest without relaunching.
#'
#' @param gpoints       giottoPoints object (optional)
#' @param gpolygons     giottoPolygon object (optional)
#' @param output        Path to write manifest.json
#' @param serve_root    The directory being served by the HTTP server — tile
#'                      URLs are computed relative to this root
#' @param url_prefix    URL at which serve_root is accessible
#' @export
export_manifest <- function(
    gpoints    = NULL,
    gpolygons  = NULL,
    output     = "lens/manifest.json",
    serve_root,
    url_prefix = "http://localhost:3000"
) {
    if (!requireNamespace("jsonlite", quietly = TRUE))
        stop("jsonlite is required: install.packages('jsonlite')")

    layers <- list()
    extent <- NULL

    if (!is.null(gpolygons)) {
        layers$polygons <- .layer_manifest(gpolygons@spatVector, "polygons", serve_root, url_prefix)
        extent <- .merge_extent(extent, layers$polygons$extent)
    }
    if (!is.null(gpoints)) {
        layers$transcripts <- .layer_manifest(gpoints@spatVector, "points", serve_root, url_prefix)
        layers$transcripts$genes <- as.list(sort(gpoints@unique_ID_cache))
        extent <- .merge_extent(extent, layers$transcripts$extent)
    }

    manifest <- list(version = "0.1.0", extent = extent, layers = layers)
    dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)
    jsonlite::write_json(manifest, output, auto_unbox = TRUE, pretty = TRUE, digits = 6)
    message("Manifest written to: ", output)
    invisible(output)
}


# ── internals ─────────────────────────────────────────────────────────────────

.layer_manifest <- function(store, type, serve_root, url_prefix) {
    tp   <- store@tiles
    bnds <- tp@bounds   # [xmin, xmax, ymin, ymax] per row
    meta <- tp@metadata # columns: tile, n_records

    tiles <- lapply(seq_len(nrow(bnds)), function(i) {
        idx <- meta$tile[i]
        list(
            index = idx,
            xmin  = bnds[i, 1], xmax = bnds[i, 2],
            ymin  = bnds[i, 3], ymax = bnds[i, 4],
            n     = meta$n_records[i],
            url   = .tile_url(store, idx, serve_root, url_prefix)
        )
    })

    disk_ext <- store@params$disk_extent  # xmin, xmax, ymin, ymax
    out <- list(
        type   = type,
        uid    = store@uid,
        extent = list(
            xmin = disk_ext[[1]], xmax = disk_ext[[2]],
            ymin = disk_ext[[3]], ymax = disk_ext[[4]]
        ),
        tiles  = tiles
    )
    if (type == "polygons") out$id_col <- "poly_ID"
    out
}

.tile_url <- function(store, tile_idx, serve_root, url_prefix) {
    tile_dir <- file.path(
        store@path,
        paste0("source_id=", store@uid),
        sprintf("tile_index=%03d", tile_idx)
    )
    # GiottoDisk writes one tile_index level per tile; stores written before
    # GiottoDisk#75 nest a second tile_index=000 level until they are rewritten
    full <- file.path(tile_dir, "part-0.parquet")
    if (!file.exists(full)) {
        legacy <- file.path(tile_dir, "tile_index=000", "part-0.parquet")
        if (!file.exists(legacy)) {
            stop("[.tile_url] no tile parquet found under '", tile_dir, "'",
                call. = FALSE)
        }
        full <- legacy
    }
    rel <- sub(paste0(normalizePath(serve_root), "/?"), "", normalizePath(full))
    paste0(url_prefix, "/", rel)
}

.merge_extent <- function(e1, e2) {
    if (is.null(e1)) return(e2)
    list(
        xmin = min(e1$xmin, e2$xmin), xmax = max(e1$xmax, e2$xmax),
        ymin = min(e1$ymin, e2$ymin), ymax = max(e1$ymax, e2$ymax)
    )
}
