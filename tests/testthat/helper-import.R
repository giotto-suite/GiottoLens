# Importing datasets (adr/0027)

# A Xenium output folder for detection: empty files where the reader only
# looks for names, and experiment.xenium
fake_xenium <- function(parent = tempfile("xen")) {
    d <- file.path(parent, "outs")
    dir.create(file.path(d, "morphology_focus"), recursive = TRUE)
    for (f in c("transcripts.parquet", "cell_boundaries.parquet", "nucleus_boundaries.parquet",
            "cells.parquet", "cell_feature_matrix.h5", "gene_panel.json",
            "morphology_focus/ch0000_dapi.ome.tif", "morphology_focus/ch0001_18s.ome.tif"))
        writeLines("x", file.path(d, f))
    jsonlite::write_json(list(pixel_size = 0.2125, run_name = "run 1", num_cells = 1234L,
        analysis_sw_version = "xenium-3.0"), file.path(d, "experiment.xenium"), auto_unbox = TRUE)
    writeLines("x", file.path(parent, "slide_he_image.ome.tif"))
    writeLines("x", file.path(parent, "slide_he_imagealignment.csv"))
    d
}
