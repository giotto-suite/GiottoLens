# Development workaround, not part of the package.
#
# GiottoDisk currently vaults three of the Atera focus images as VRT stubs
# (the sourceAdopt VRT bug), so their @file_path is not a TIFF the viewer can
# read. Until the fix lands, this points each image back at its original
# OME-TIFF, as the fixed reference mode will (`export_image = FALSE`): the
# real file in @file_path and a VRT rebuilt over it in @raster_object, with
# the extent unchanged. GiottoLens only reads @file_path (.image_source()),
# so nothing in the package changes when the fix replaces this script.
#
#   source("dev/atera_images.R")
#   g <- repoint_images(g, "<...>/WTA_Preview_FFPE_Breast_Cancer_outs/morphology_focus")
#   viewer <- launch_lens(g)

repoint_images <- function(g, dir) {
    files <- list.files(dir, pattern = "\\.ome\\.tif$", full.names = TRUE)
    # ch0001_atp1a1_cd45_e-cadherin.ome.tif -> atp1a1_cd45_e-cadherin
    stems <- sub("^ch[0-9]+_", "", sub("\\.ome\\.tif$", "", basename(files)))
    for (nm in names(g@images)) {
        f <- files[match(nm, stems)]
        if (is.na(f)) {
            message("no original for image '", nm, "'; left as is")
            next
        }
        img <- g@images[[nm]]
        r <- suppressWarnings(terra::rast(GiottoClass:::.tif_vrt(f, page = 1L, pyramid = TRUE)))
        terra::ext(r) <- terra::ext(img@raster_object)
        img@raster_object <- r
        img@file_path <- normalizePath(f)
        g@images[[nm]] <- img
    }
    g
}
