# Export GiottoDisk-backed spatial objects to a GiottoAtlas manifest.json
#
# Usage:
#   library(GiottoClass)
#   gpoints  <- readRDS("path/to/gpoints")[[1]]
#   gpolygons <- readRDS("path/to/gpoly")
#
#   export_manifest(
#     gpoints   = gpoints,
#     gpolygons = gpolygons,
#     output    = "viewer/manifest.json",
#     artifacts_dir = "/path/to/artifacts",   # directory being served by HTTP
#     url_prefix    = "http://localhost:3000"  # URL that maps to artifacts_dir
#   )

export_manifest <- function(
    gpoints   = NULL,
    gpolygons = NULL,
    output    = "viewer/manifest.json",
    artifacts_dir,
    url_prefix = "http://localhost:3000"
) {
    if (!requireNamespace("jsonlite", quietly = TRUE)) {
        stop("jsonlite is required: install.packages('jsonlite')")
    }

    layers <- list()
    extent <- NULL

    if (!is.null(gpolygons)) {
        layers$polygons <- .layer_manifest(gpolygons@spatVector, "polygons", artifacts_dir, url_prefix)
        extent <- .merge_extent(extent, layers$polygons$extent)
    }
    if (!is.null(gpoints)) {
        layers$transcripts <- .layer_manifest(gpoints@spatVector, "points", artifacts_dir, url_prefix)
        layers$transcripts$genes <- as.list(sort(gpoints@unique_ID_cache))
        extent <- .merge_extent(extent, layers$transcripts$extent)
    }

    manifest <- list(version = "0.1.0", extent = extent, layers = layers)
    jsonlite::write_json(manifest, output, auto_unbox = TRUE, pretty = TRUE, digits = 6)
    message("Manifest written to: ", output)
    invisible(output)
}


# ── internals ────────────────────────────────────────────────────────────────

.layer_manifest <- function(store, type, artifacts_dir, url_prefix) {
    tp   <- store@tiles
    bnds <- tp@bounds   # [xmin, xmax, ymin, ymax] per row
    meta <- tp@metadata # columns: tile, n_records

    tiles <- lapply(seq_len(nrow(bnds)), function(i) {
        idx <- meta$tile[i]
        list(
            index  = idx,
            xmin   = bnds[i, 1],
            xmax   = bnds[i, 2],
            ymin   = bnds[i, 3],
            ymax   = bnds[i, 4],
            n      = meta$n_records[i],
            url    = .tile_url(store, idx, artifacts_dir, url_prefix)
        )
    })

    disk_ext <- store@params$disk_extent  # xmin, xmax, ymin, ymax
    list(
        type   = type,
        uid    = store@uid,
        extent = list(
            xmin = disk_ext[[1]], xmax = disk_ext[[2]],
            ymin = disk_ext[[3]], ymax = disk_ext[[4]]
        ),
        tiles  = tiles
    )
}

.tile_url <- function(store, tile_idx, artifacts_dir, url_prefix) {
    full <- file.path(
        store@path,
        paste0("source_id=", store@uid),
        sprintf("tile_index=%03d", tile_idx),
        "tile_index=000",
        "part-0.parquet"
    )
    # Make relative to artifacts_dir, then prefix with URL
    rel <- sub(paste0(normalizePath(artifacts_dir), "/?"), "", normalizePath(full))
    paste0(url_prefix, "/", rel)
}

.merge_extent <- function(e1, e2) {
    if (is.null(e1)) return(e2)
    list(
        xmin = min(e1$xmin, e2$xmin),
        xmax = max(e1$xmax, e2$xmax),
        ymin = min(e1$ymin, e2$ymin),
        ymax = max(e1$ymax, e2$ymax)
    )
}