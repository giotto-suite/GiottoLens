# Projects opened in the viewer, from R or the start page (adr/0019)

ask <- function(v, ...) get("private", v$.__enclos_env__)$ask(list(...))

test_that("recent projects: newest first, once each, up to the cap", {
    f <- tempfile(fileext = ".json")
    expect_identical(nrow(.recent_projects(f)), 0L)
    dirs <- vapply(1:12, function(i) { d <- tempfile(); dir.create(d); d }, "")
    for (d in dirs) .add_recent(d, f)
    .add_recent(dirs[[5]], f)
    r <- .recent_projects(f)
    expect_identical(nrow(r), .lens_recent_max)
    expect_identical(r$path[[1]], normalizePath(dirs[[5]]))
    expect_identical(anyDuplicated(r$path), 0L)
    expect_identical(r$path[[2]], normalizePath(dirs[[12]]))
})

test_that("a snapshot's spatial units and feature types come from its manifest", {
    fx <- lens_image_fixture()
    src <- fx$g@source
    info <- GiottoDisk::snapshotInfo(src)
    tag <- info$tag[info$name == "fixture"]
    k <- .manifest_keys(file.path(src@path, "giottosave", tag, "manifest.json"))
    expect_identical(k$spat_units, "cell")
    expect_identical(k$feat_types, "rna")
    expect_identical(.manifest_keys(tempfile()), list())
    # Newest first; other tests may have saved into the fixture's project
    s <- .project_snapshots(src)
    created <- vapply(s, `[[`, "", "created")
    expect_identical(created, sort(created, decreasing = TRUE))
    s <- Filter(function(x) x$name == "fixture", s)[[1]]
    expect_match(s$created, "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ$")
    expect_identical(s$spat_units, list("cell"))
})

test_that("left-out keys come from the object: preferred, its defaults, its first", {
    bx <- lens_bins_fixture()
    expect_identical(.default_keys(bx$mem), list(spat_unit = "bin", feat_type = NULL))
    expect_identical(.default_keys(bx$mem, spat_unit = NULL)$spat_unit, NULL)
    fx <- lens_image_fixture()
    expect_identical(.default_keys(fx$g, prefer_unit = "nope"),
        list(spat_unit = "cell", feat_type = "rna"))
})

test_that("open_project() shows the start page, and checkout() a snapshot as saved", {
    bx <- lens_bins_fixture()
    proj <- bx$g@source@path
    v <- launch_lens(open = FALSE)
    on.exit(v$close(), add = TRUE)
    priv <- get("private", v$.__enclos_env__)
    expect_error(v$open_project(tempdir()), "not a GiottoDisk project")
    expect_error(v$checkout("fixture"), "no project open")

    v$open_project(proj)
    m <- jsonlite::fromJSON(file.path(priv$session, "manifest.json"))
    expect_true(m$empty)
    expect_identical(m$project, normalizePath(proj))
    expect_false(priv$loaded)
    expect_output(print(v), "project:")
    expect_error(v$gobject(), "or viewer\\$checkout\\(name\\) first")
    expect_identical(.recent_projects()$path[[1]], normalizePath(proj))

    n <- nrow(GiottoDisk::snapshotInfo(priv$project))
    v$checkout("fixture")
    expect_true(priv$loaded)
    expect_identical(priv$spat_unit, "bin")
    expect_null(priv$feat_type)
    expect_length(priv$cell_ids, 900L)
    expect_identical(nrow(GiottoDisk::snapshotInfo(priv$project)), n)
    expect_error(v$checkout("nope"), "no snapshot 'nope'.*fixture")
})

test_that("a snapshot without a manifest is shown as it is, without a new save", {
    bx <- lens_bins_fixture()
    g <- .fixture_project(bx$mem)
    src <- g@source
    on.exit(unlink(src@path, recursive = TRUE), add = TRUE)
    info <- GiottoDisk::snapshotInfo(src)
    unlink(file.path(src@path, "giottosave", info$tag, "manifest.json"))
    v <- launch_lens(project = src@path, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$checkout("fixture", spat_unit = "bin", feat_type = NULL)
    expect_identical(get("private", v$.__enclos_env__)$snapshot, info$tag)
    expect_identical(nrow(GiottoDisk::snapshotInfo(src)), 1L)
})

test_that("Lens work is not dropped by opening without discard", {
    bx <- lens_bins_fixture()
    v <- launch_lens(bx$g, spat_unit = "bin", feat_type = NULL, open = FALSE)
    on.exit(v$close(), add = TRUE)
    v$annotations <- list(list(id = "a", name = "x", type = "polygon", geojson = "{}"))
    proj <- bx$g@source@path
    expect_error(v$open_project(proj), "1 annotation; pass `discard = TRUE`")
    expect_error(v$checkout("fixture"), "1 annotation")
    res <- ask(v, op = "open", path = proj, name = "fixture")
    expect_identical(res$code, "work")
    expect_match(res$error, "1 annotation")
    expect_message(res <- ask(v, op = "open", path = proj, name = "fixture", discard = TRUE),
        "opened snapshot 'fixture'")
    expect_null(res$error)
    expect_identical(v$annotations, list())
    v$open_project(proj)
    expect_false(get("private", v$.__enclos_env__)$loaded)
})

test_that("the page asks R over the socket and gets answers back", {
    skip_if_not_installed("websocket")
    bx <- lens_bins_fixture()
    proj <- bx$g@source@path
    v <- launch_lens(project = proj, open = FALSE)
    on.exit(v$close(), add = TRUE)
    a <- ws_client(ws_url(v), load = 1L)
    expect_true(pump_until(function() v$connected()))
    answer <- function(id) {
        hit <- NULL
        pump_until(function() {
            for (m in a$state$msgs) if (m$type == "answer" && identical(m$data$id, id)) hit <<- m$data
            !is.null(hit)
        })
        hit
    }
    send <- function(id, ...) a$ws$send(jsonlite::toJSON(list(type = "ask", id = id,
        data = list(...)), auto_unbox = TRUE))

    send("1", op = "projects")
    r <- answer("1")
    expect_identical(r$data$current, normalizePath(proj))
    expect_false(r$data$browse)
    send("2", op = "snapshots", path = proj)
    r <- answer("2")
    expect_true("fixture" %in% vapply(r$data$snapshots, `[[`, "", "name"))
    expect_null(r$data$current)
    send("3", op = "snapshots", path = tempdir())
    expect_match(answer("3")$error, "not a GiottoDisk project")
    send("4", op = "nope")
    expect_identical(answer("4")$error, "unknown request")
    expect_message(send("5", op = "open", path = proj, name = "fixture"), NA)
    expect_true(pump_until(function() get("private", v$.__enclos_env__)$loaded))
    info <- GiottoDisk::snapshotInfo(bx$g@source)
    expect_identical(answer("5")$data$snapshot, info$tag[info$name == "fixture"])
    expect_true(any(vapply(a$state$msgs, function(m) m$type == "reload", NA)))
    a$ws$close()
})
