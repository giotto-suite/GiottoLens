#' Export a GiottoLens manifest.json
#'
#' Generates the manifest JSON that tells the viewer where to find tile data,
#' and, when polygons are given, `cells.parquet` next to it: one row per cell
#' with its centroid, in the viewer's cell order. Called internally by
#' [launch_lens()]. Tile URLs are relative to the viewer page
#' (`data/<layer>/...`) and are answered by the viewer's server, which mounts
#' each layer's store directory under that name.
#'
#' @param gpoints   giottoPoints backed by a GiottoDisk tile store (optional)
#' @param gpolygons giottoPolygon backed by a GiottoDisk tile store (optional)
#' @param output    Path to write manifest.json
#' @return `output`, invisibly.
#' @export
export_manifest <- function(gpoints = NULL, gpolygons = NULL, output) {
    .export_session(gpoints, gpolygons, output, transfer = "auto")
    invisible(output)
}

# Writes manifest.json (and cells.parquet) and returns the cell IDs in the
# viewer's cell order (NULL without polygons).
.export_session <- function(gpoints, gpolygons, output, transfer = "auto") {
    layers <- list()
    extent <- NULL
    cells  <- NULL
    dir.create(dirname(output), recursive = TRUE, showWarnings = FALSE)

    if (!is.null(gpolygons)) {
        cells <- .build_cells(gpolygons@spatVector)
        layers$polygons <- .layer_manifest(gpolygons@spatVector, "polygons", cells$tiles)
        layers$polygons$cells <- list(url = "session/cells.parquet", n = nrow(cells$table))
        .write_cells(cells$table, file.path(dirname(output), "cells.parquet"))
        extent <- .merge_extent(extent, layers$polygons$extent)
    }
    if (!is.null(gpoints)) {
        layers$transcripts <- .layer_manifest(gpoints@spatVector, "transcripts")
        layers$transcripts$genes <- as.list(sort(gpoints@unique_ID_cache))
        extent <- .merge_extent(extent, layers$transcripts$extent)
    }
    if (!length(layers))
        stop("[export_manifest] provide gpoints and/or gpolygons", call. = FALSE)

    manifest <- list(version = "0.3.0", extent = extent, transfer = transfer,
        layers = layers)
    jsonlite::write_json(manifest, output, auto_unbox = TRUE, digits = NA)
    cells$table$cell_ID
}

# Directories the server mounts under data/<layer>/ (layer name → store path)
.layer_mounts <- function(gpoints = NULL, gpolygons = NULL) {
    mounts <- list()
    if (!is.null(gpolygons)) mounts$polygons    <- gpolygons@spatVector@path
    if (!is.null(gpoints))   mounts$transcripts <- gpoints@spatVector@path
    mounts
}


# ── internals ─────────────────────────────────────────────────────────────────

# `cell_tiles`: per-tile offsets and centroid bounds from .build_cells()
.layer_manifest <- function(store, layer, cell_tiles = NULL) {
    tp   <- store@tiles
    bnds <- tp@bounds   # [xmin, xmax, ymin, ymax] per row
    meta <- tp@metadata # columns: tile, n_records

    tiles <- lapply(seq_len(nrow(bnds)), function(i) {
        idx  <- meta$tile[i]
        file <- .tile_file(store, idx)
        t <- list(
            index = idx,
            xmin  = bnds[i, 1], xmax = bnds[i, 2],
            ymin  = bnds[i, 3], ymax = bnds[i, 4],
            n     = meta$n_records[i],
            url   = paste0("data/", layer, "/", file),    # Range reads
            file  = paste0("files/", layer, "/", file),   # whole file
            # Lets the viewer skip a size probe before its Range reads
            bytes = file.size(file.path(store@path, file))
        )
        if (!is.null(cell_tiles)) {
            ct <- cell_tiles[i, ]
            # Rows of this tile are cells offset .. offset + n - 1
            t$offset <- ct$offset
            t$n      <- ct$n
            t$cbounds <- c(ct$cxmin, ct$cxmax, ct$cymin, ct$cymax)
        }
        t
    })

    disk_ext <- store@params$disk_extent  # xmin, xmax, ymin, ymax
    out <- list(
        type   = if (layer == "polygons") "polygons" else "points",
        uid    = store@uid,
        extent = list(
            xmin = disk_ext[[1]], xmax = disk_ext[[2]],
            ymin = disk_ext[[3]], ymax = disk_ext[[4]]
        ),
        tiles  = tiles
    )
    if (layer == "polygons") out$id_col <- "poly_ID"
    out
}

# Tile parquet path relative to the store directory
.tile_file <- function(store, tile_idx) {
    tile_dir <- file.path(
        paste0("source_id=", store@uid),
        sprintf("tile_index=%03d", tile_idx)
    )
    # GiottoDisk writes one tile_index level per tile; stores written before
    # GiottoDisk#75 nest a second tile_index=000 level until they are rewritten
    for (rel in c(file.path(tile_dir, "part-0.parquet"),
                  file.path(tile_dir, "tile_index=000", "part-0.parquet"))) {
        if (file.exists(file.path(store@path, rel))) return(rel)
    }
    stop("[.tile_file] no tile parquet found under '",
        file.path(store@path, tile_dir), "'", call. = FALSE)
}

# ── Cells ────────────────────────────────────────────────────────────────────
#
# The viewer numbers cells 0..N-1 by concatenating the polygon tiles in
# manifest order. Each tile is then a contiguous range of cell indices, so the
# browser maps a tile row to its cell by addition, keeps per-cell data in
# typed arrays, and never needs string IDs. R keeps the IDs and translates.

.build_cells <- function(store) {
    tile_idx <- store@tiles@metadata$tile
    parts <- lapply(tile_idx, function(idx) {
        f    <- file.path(store@path, .tile_file(store, idx))
        cols <- names(arrow::open_dataset(f)$schema)
        tbl  <- arrow::read_parquet(f,
            col_select = intersect(c("poly_ID", "x_index", "y_index"), cols))
        if (!"poly_ID" %in% names(tbl)) tbl$poly_ID <- NA_character_
        tbl
    })
    n      <- vapply(parts, nrow, integer(1L))
    offset <- c(0L, cumsum(n)[-length(n)])
    rng    <- function(f) vapply(parts, function(p)
        if (nrow(p)) f(p) else NA_real_, numeric(1L))
    table <- data.frame(
        cell_ID = as.character(unlist(lapply(parts, `[[`, "poly_ID"), use.names = FALSE)),
        x = unlist(lapply(parts, `[[`, "x_index"), use.names = FALSE),
        y = unlist(lapply(parts, `[[`, "y_index"), use.names = FALSE)
    )
    dup <- anyDuplicated(stats::na.omit(table$cell_ID))
    if (dup)
        warning("[export_manifest] cell ID '", table$cell_ID[dup],
            "' appears in more than one polygon tile row", call. = FALSE)
    list(
        table = table,
        tiles = data.frame(
            index = tile_idx, offset = offset, n = n,
            cxmin = rng(function(p) min(p$x_index)), cxmax = rng(function(p) max(p$x_index)),
            cymin = rng(function(p) min(p$y_index)), cymax = rng(function(p) max(p$y_index))
        )
    )
}

# The viewer reads x and y into Float32Arrays at boot; cell_ID is only read
# when a tooltip needs an ID whose polygon tile is not loaded.
.write_cells <- function(table, path) {
    arrow::write_parquet(arrow::arrow_table(
        x = arrow::Array$create(table$x)$cast(arrow::float32()),
        y = arrow::Array$create(table$y)$cast(arrow::float32()),
        cell_ID = table$cell_ID
    ), path)
}

.merge_extent <- function(e1, e2) {
    if (is.null(e1)) return(e2)
    list(
        xmin = min(e1$xmin, e2$xmin), xmax = max(e1$xmax, e2$xmax),
        ymin = min(e1$ymin, e2$ymin), ymax = max(e1$ymax, e2$ymax)
    )
}
