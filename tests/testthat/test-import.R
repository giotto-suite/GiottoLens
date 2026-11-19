# Importing a dataset into a new project (adr/0027)

ask <- function(v, ...) get("private", v$.__enclos_env__)$ask(list(...), function(r) NULL)

skip_no_giotto <- function() {
    skip_if_not_installed("Giotto")
    skip_if_not_installed("GiottoDisk")
}

field <- function(form, key) Filter(function(f) f$key == key, form$fields)[[1L]]

test_that("detection fills the form from Giotto's Xenium reader", {
    skip_no_giotto()
    d <- fake_xenium()
    base <- tempfile("base")
    dir.create(base)
    f <- .import_detect("xenium", d, base, "t")
    expect_identical(f$dir, normalizePath(d))
    expect_null(f$problem)
    expect_identical(field(f, "transcript_path")$value,
        file.path(normalizePath(d), "transcripts.parquet"))
    expect_true(field(f, "transcript_path")$info$exists)
    b <- field(f, "bounds_path")$value
    expect_identical(vapply(b, `[[`, "", "name"), c("cell", "nucleus"))
    im <- field(f, "load_images")$value
    expect_identical(vapply(im, `[[`, "", "name"), c("dapi", "18s"))
    al <- field(f, "load_aligned_images")$value
    expect_identical(al[[1L]]$name, "he")
    expect_identical(field(f, "feat_type")$value[[1L]]$feat_type, "rna")
    expect_identical(field(f, "qv_threshold")$value, 20)
    labels <- vapply(f$info, `[[`, "", "label")
    expect_true(all(c("Run", "Cells", "Pixel size") %in% labels))
    # the parent folder's name for a folder named outs
    expect_identical(f$project, file.path(base, basename(dirname(d))))
    # the aligned H&E found beside it is the one argument as detected
    expect_match(f$code, "load_aligned_images = list\\(he = c\\(")
    expect_match(f$code, "backend = src")
})

test_that("detection stops with the reader's error", {
    skip_no_giotto()
    d <- fake_xenium()
    unlink(file.path(d, "cell_feature_matrix.h5"))
    expect_error(.import_detect("xenium", d, tempdir(), "t"), "Giotto could not read")
    expect_error(.import_detect("visium", d, tempdir(), "t"), "`platform` must be one of")
    expect_error(.import_detect("xenium", file.path(d, "nope"), tempdir(), "t"), "no folder")
})

test_that("only values that differ from the reader's defaults become arguments", {
    skip_no_giotto()
    d <- fake_xenium()
    unlink(file.path(dirname(d), "slide_he_imagealignment.csv"))
    f <- .import_detect("xenium", d, tempdir(), "t")
    expect_identical(.import_form_args(f, list(), "t"), list())
    # the form's values sent back as the page sends them (with path info)
    vals <- lapply(stats::setNames(f$fields, vapply(f$fields, `[[`, "", "key")), `[[`, "value")
    expect_identical(.import_form_args(f, vals, "t"), list())

    im <- field(f, "load_images")$value
    im[[2L]]$on <- FALSE
    a <- .import_form_args(f, list(load_images = im, qv_threshold = 30), "t")
    expect_identical(a$qv_threshold, 30)
    expect_identical(a$load_images, list(dapi = im[[1L]]$path))

    b <- field(f, "bounds_path")$value
    b[[2L]]$on <- FALSE
    expect_identical(.import_form_args(f, list(bounds_path = b), "t")$bounds_path,
        list(cell = "cell"))
    b[[1L]]$path <- file.path(d, "cells.parquet")
    expect_identical(.import_form_args(f, list(bounds_path = b), "t")$bounds_path,
        list(cell = file.path(d, "cells.parquet")))
    a <- .import_form_args(f, list(bounds_path = list(), load_images = list()), "t")
    expect_true("bounds_path" %in% names(a) && is.null(a$bounds_path))
    expect_true("load_images" %in% names(a) && is.null(a$load_images))

    ft <- list(list(feat_type = "rna", keywords = ""), list(feat_type = "neg", keywords = "NegControl, Blank"))
    a <- .import_form_args(f, list(feat_type = ft), "t")
    expect_identical(a$feat_type, c("rna", "neg"))
    expect_identical(a$split_keyword, list(c("NegControl", "Blank")))

    expect_identical(.import_form_args(f, list(load_cellmeta = TRUE), "t"),
        list(load_cellmeta = TRUE))
    expect_error(.import_form_args(f, list(load_transcripts = "yes"), "t"), "true or false")
    expect_error(.import_form_args(f, list(expression_path = file.path(d, "nope.h5")), "t"),
        "no file")
    expect_error(.import_form_args(f, list(expression_path = ""), "t"), "turn off `load_expression`")
    expect_identical(.import_form_args(f, list(expression_path = "", load_expression = FALSE), "t"),
        list(load_expression = FALSE))
    expect_error(.import_form_args(f, list(feat_type = list(list(feat_type = "rna",
        keywords = "x"))), "t"), "first row takes no keywords")
    expect_error(.import_form_args(f, list(qv_threshold = -1), "t"), "at least 0")
    expect_error(.import_form_args(f, list(nope = 1), "t"), "unknown field")
})

test_that("a project folder is new or empty, local, in a folder that exists", {
    base <- tempfile("base")
    dir.create(base)
    expect_identical(.import_project_check(file.path(base, "p"), "t"),
        normalizePath(file.path(base, "p"), mustWork = FALSE))
    dir.create(file.path(base, "empty"))
    expect_no_error(.import_project_check(file.path(base, "empty"), "t"))
    dir.create(file.path(base, "full"))
    writeLines("x", file.path(base, "full", "a"))
    expect_error(.import_project_check(file.path(base, "full"), "t"), "not empty")
    expect_error(.import_project_check(file.path(base, "full", "a"), "t"), "is a file")
    expect_error(.import_project_check(file.path(base, "no", "p"), "t"), "no folder")
    expect_error(.import_project_check("", "t"), "must be a folder path")
    expect_identical(.cloud_synced(c("/Users/a/Library/CloudStorage/GoogleDrive-x/p",
        "/Users/a/OneDrive - BU/p", "C:\\Users\\a\\OneDrive\\p", "/Users/a/Dropbox/p",
        "/Users/a/Documents/p", "/Users/a/OneDriveNot")), c(TRUE, TRUE, TRUE, TRUE, FALSE, TRUE))

    # a name taken: _2, _3...
    d <- file.path(base, "full")
    expect_identical(.import_default_project(file.path(tempdir(), "full"), base),
        file.path(base, "full_2"))
    expect_identical(.import_default_project(file.path(tempdir(), "my run (1)"), base),
        file.path(base, "my_run_1"))
    expect_identical(.import_snapshot_check("imported", "t"), "imported")
    expect_error(.import_snapshot_check("a b", "t"), "`snapshot` must be")
})

test_that("the default folder: preference, else the fallback, else the working directory", {
    withr::local_options(GiottoLens.preferences_file = tempfile(fileext = ".json"))
    expect_identical(.import_base("/x"), "/x")
    expect_identical(.import_base(), getwd())
    lens_preferences(import_dir = "/data/projects")
    expect_identical(.import_base("/x"), "/data/projects")
})

test_that("the R code passes the arguments given and saves a snapshot", {
    spec <- list(fun = "createGiottoXeniumObject", dir_arg = "xenium_dir")
    code <- .import_code(spec, "/d", list(qv_threshold = 30, load_images = NULL), "/p", "imported",
        "first")
    expect_identical(strsplit(code, "\n")[[1L]], c(
        "GiottoDisk::setArtifactDumpDir(\"/p\")",
        "src <- GiottoDisk::sourceCreate(\"/p\")",
        "g <- Giotto::createGiottoXeniumObject(",
        "    xenium_dir = \"/d\",",
        "    qv_threshold = 30,",
        "    load_images = NULL,",
        "    backend = src",
        ")",
        "GiottoDisk::snapshotSave(src, g, name = \"imported\", description = \"first\")"))
    expect_error(.import_args_check(list(fun = "createGiottoXeniumObject", dir_arg = "xenium_dir"),
        list(nope = 1), "t"), "not an argument of Giotto::createGiottoXeniumObject")
})

test_that("a failed import removes what it wrote, and only that", {
    p <- tempfile("proj")
    dir.create(file.path(p, "giottosave"), recursive = TRUE)
    .import_cleanup(p, created = TRUE)
    expect_false(dir.exists(p))
    dir.create(file.path(p, "x"), recursive = TRUE)
    .import_cleanup(p, created = FALSE)
    expect_true(dir.exists(p))
    expect_length(list.files(p, all.files = TRUE, no.. = TRUE), 0L)
})

test_that("the page asks: detect, path status, code; refused while an import runs", {
    skip_no_giotto()
    d <- fake_xenium()
    v <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    f <- ask(v, op = "import_detect", platform = "xenium", dir = d)$data
    expect_identical(f$platform, "xenium")
    p <- ask(v, op = "import_paths", paths = list(file.path(d, "gene_panel.json"), "/no/such"))$data
    expect_identical(vapply(p, `[[`, NA, "exists"), c(TRUE, FALSE))
    code <- ask(v, op = "import_code", platform = "xenium", dir = d,
        values = list(qv_threshold = 25), project = file.path(tempdir(), "p1"),
        snapshot = "s1")$data$code
    expect_match(code, "qv_threshold = 25")
    expect_match(code, "name = \"s1\"")
    priv <- get("private", v$.__enclos_env__)
    priv$import_job <- 99L
    expect_error(ask(v, op = "import_run", platform = "xenium", dir = d,
        project = file.path(tempdir(), "p2")), "an import is running")
})

# A real Xenium folder: GIOTTOLENS_XENIUM_DIR. Runs the import job, opens the
# snapshot and starts Preprocessing.
test_that("import_dataset() imports a Xenium folder and opens it", {
    skip_no_giotto()
    skip_on_cran()
    dir <- Sys.getenv("GIOTTOLENS_XENIUM_DIR")
    skip_if(!nzchar(dir), "GIOTTOLENS_XENIUM_DIR not set")
    proj <- tempfile("xen_proj")
    on.exit(unlink(proj, recursive = TRUE), add = TRUE)
    v <- launch_lens(open = FALSE)
    on.exit(v$close(discard = TRUE), add = TRUE)
    r <- v$import_dataset(dir, project = proj, load_images = NULL, analyze = TRUE)
    expect_identical(r$path, normalizePath(proj))
    expect_match(r$code, "load_images = NULL")
    priv <- get("private", v$.__enclos_env__)
    expect_true(priv$loaded)
    expect_gt(length(priv$cell_ids), 0L)
    info <- GiottoDisk::snapshotInfo(priv$project)
    expect_identical(info$creator[info$name == "imported"], "GiottoLens")
    # analyze = TRUE: Preprocessing starts once the snapshot is shown
    expect_true(pump_until(function() !is.null(priv$lens_analysis), 120))
    expect_true(get("private", priv$lens_analysis$.__enclos_env__)$started)
    expect_null(priv$analyze_next)
})
