# The viewer's work is kept in a working bundle in the project and saved as a
# bundle beside it (R/bundle.R, adr/0026).

# ── Helpers ──────────────────────────────────────────────────────────────────

# A viewer on the bins fixture written into a project of its own
bundle_viewer <- function(td = tempfile("lensproj_")) {
    bx <- lens_bins_fixture()
    v <- suppressMessages(launch_lens(bx$mem, spat_unit = "bin", feat_type = NULL,
        open = FALSE, project = td))
    list(v = v, bx = bx, td = td, priv = lens_priv(v),
        done = function() { v$close(discard = TRUE); unlink(td, recursive = TRUE) })
}

# Some of every kind of work, for a viewer from bundle_viewer()
add_work <- function(r) {
    v <- r$v
    ids <- r$priv$cell_ids
    suppressMessages(v$push_metadata(data.frame(cell_ID = ids,
        half = ifelse(seq_along(ids) <= 450L, "left", "right"), score = seq_along(ids))))
    v$set_column_type("score", "categorical")
    v$select(lens_categories("half", "left"))
    v$select(lens_cells(ids[1:3]), source = "picked", replace = FALSE)
    v$save_selection("top", lens_cells(ids[1:20]))
    big <- data.frame(cell_ID = ids, x = seq_along(ids), y = 1)
    big <- big[rep(seq_len(nrow(big)), 6L), ]
    suppressMessages(v$push_panel(list(mark = "point",
        encoding = list(x = list(field = "x"), y = list(field = "y"))), data = big, id = "big"))
    suppressMessages(v$push_panel(list(mark = "bar"), data = data.frame(a = 1:3), id = "small"))
    r$priv$config_json <- '{"version":3,"colorBy":"half"}'
    invisible(r)
}

# Work as a viewer elsewhere left it: `r`'s working bundle copied to another
# session folder, written by `user` on `host`
left_work <- function(r, host = Sys.info()[["nodename"]], user = Sys.info()[["user"]], pid = -1) {
    r$priv$write_state(force = TRUE)
    id <- tolower(.rand_id(8L))
    dir <- file.path(r$td, "lens", paste0("session-", id))
    dir.create(dir)
    file.copy(list.files(r$priv$work, full.names = TRUE), dir, recursive = TRUE)
    b <- jsonlite::fromJSON(file.path(dir, "bundle.json"), simplifyVector = FALSE)
    b$session <- id
    b$host <- host
    b$user <- user
    b$pid <- pid
    writeLines(.bundle_json(b), file.path(dir, "bundle.json"))
    dir
}

# ── Working bundle and autosave ──────────────────────────────────────────────

test_that("work goes to the working bundle in the project and is served under work/", {
    skip_if_not_installed("curl")
    skip_on_os("windows")  # file.symlink
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    w <- r$priv$work
    expect_identical(w, normalizePath(file.path(r$td, "lens",
        paste0("session-", r$priv$session_id))))
    expect_false(grepl(r$priv$token, w, fixed = TRUE))
    add_work(r)
    url <- r$priv$cached_meta$columns[[1L]]$url
    expect_match(url, "^work/metadata/")
    expect_true(file.exists(file.path(w, sub("^work/", "", url))))
    expect_match(r$priv$pushed$big$data_url, "^work/panels/")
    res <- http_get(lens_data_url(r$v, url))
    expect_identical(res$status_code, 200L)
    expect_identical(res$content, readBin(file.path(w, sub("^work/", "", url)), "raw", 1e6))
    expect_identical(http_get(lens_data_url(r$v, "work/../bundle.json"))$status_code, 404L)
    # A link placed in the working bundle that leads out of it is not followed
    secret <- tempfile("secret_")
    writeLines("secret", secret)
    on.exit(unlink(secret), add = TRUE)
    file.symlink(secret, file.path(w, "metadata", "leak.parquet"))
    expect_identical(http_get(lens_data_url(r$v, "work/metadata/leak.parquet"))$status_code, 404L)
    expect_true(r$priv$write_state(force = TRUE))
    st <- jsonlite::fromJSON(file.path(w, "state.json"), simplifyVector = FALSE)
    expect_setequal(names(st$rules), c("r", "picked"))
    expect_identical(names(st$selections), "top")
    b <- jsonlite::fromJSON(file.path(w, "bundle.json"))
    expect_identical(b$kind, "session")
    expect_identical(b$user, Sys.info()[["user"]])
    expect_identical(b$snapshot, r$priv$snapshot)
    expect_identical(b$cells$n, 900L)
    expect_identical(readLines(file.path(w, "config.json")), r$priv$config_json)
})

test_that("the working bundle is written as the work changes", {
    old <- options(GiottoLens.autosave_interval = 0.1)
    on.exit(options(old), add = TRUE)
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    state <- function() .read_bundle_json(file.path(r$priv$work, "state.json"))
    r$v$save_selection("top", lens_cells(r$priv$cell_ids[1:5]))
    expect_true(pump_until(function() identical(names(state()$selections), "top")))
    r$v$remove_selection("top")
    expect_true(pump_until(function() !length(state()$selections)))
})

test_that("work not saved stays in the project when the viewer closes, and opens again", {
    r <- bundle_viewer()
    on.exit(unlink(r$td, recursive = TRUE), add = TRUE)
    add_work(r)
    w <- r$priv$work
    expect_message(r$v$close(), "work not saved .* is kept in")
    expect_true(dir.exists(w))
    v2 <- suppressMessages(launch_lens(project = r$td, open = FALSE))
    on.exit(v2$close(discard = TRUE), add = TRUE)
    s <- v2$saves(sessions = TRUE)
    left <- s[s$kind == "session", ]
    expect_identical(left$name, basename(w))
    expect_false(left$live)
    expect_identical(nrow(v2$saves()), 0L)
    suppressMessages(v2$open_save(basename(w)))
    expect_false(dir.exists(w))
    expect_identical(v2$selections()$name, "top")
    # Taken over, and still not saved
    expect_match(lens_priv(v2)$unsaved_work(), "1 saved selection")
})

test_that("close(discard = TRUE) deletes work not saved", {
    r <- bundle_viewer()
    on.exit(unlink(r$td, recursive = TRUE), add = TRUE)
    add_work(r)
    w <- r$priv$work
    r$v$close(discard = TRUE)
    expect_false(dir.exists(w))
    expect_error(r$v$close(discard = NA), "TRUE or FALSE")
})

# ── Save, open and delete from R ─────────────────────────────────────────────

test_that("a save copies the work, keeps its snapshot and counts as saved", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    expect_error(r$v$save("a.b"), "letters, digits")
    expect_error(r$v$save("session-x"), "working bundles")
    add_work(r)
    snap <- GiottoDisk::snapshotInfo(r$priv$project)
    GiottoDisk::snapshotMetadata(r$priv$project, snap$name[[1L]], keep = FALSE)
    expect_match(r$priv$unsaved_work(), "2 rules, 1 saved selection, 2 pushed panels")
    tag <- suppressMessages(r$v$save("first", description = "for the paper", labels = c("x", "y")))
    expect_match(tag, "^first\\.[a-z0-9]{8}$")
    dir <- file.path(r$td, "lens", tag)
    b <- jsonlite::fromJSON(file.path(dir, "bundle.json"))
    expect_identical(b$kind, "save")
    expect_identical(b$name, "first")
    expect_identical(b$description, "for the paper")
    expect_identical(b$labels, c("x", "y"))
    expect_null(b$pid)
    expect_true(GiottoDisk::snapshotInfo(r$priv$project)$keep[[1L]])
    st <- jsonlite::fromJSON(file.path(dir, "state.json"), simplifyVector = FALSE)
    expect_true(all(file.exists(file.path(dir, .bundle_files(st)))))
    expect_true(file.exists(file.path(dir, "config.json")))
    expect_null(r$priv$unsaved_work())
    s <- r$v$saves()
    expect_identical(s$name, "first")
    expect_identical(s$description, "for the paper")
    expect_identical(s$labels, "x, y")
    expect_error(r$v$save("first"), "exists; pass `overwrite = TRUE`")
    r$v$save_selection("bottom", lens_cells(r$priv$cell_ids[880:900]))
    expect_match(r$priv$unsaved_work(), "2 saved selections")
    expect_error(r$v$set_object(r$bx$mem, spat_unit = "bin", feat_type = NULL, project = tempfile()),
        "work not saved: .*save it with save\\(name\\)")
    tag2 <- suppressMessages(r$v$save("first", overwrite = TRUE))
    expect_false(dir.exists(dir))
    expect_identical(r$v$saves()$name, "first")
    expect_true(dir.exists(file.path(r$td, "lens", tag2)))
    r$v$delete_save("first")
    expect_identical(nrow(r$v$saves()), 0L)
})

test_that("a save opens with its snapshot and its work", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    sel <- r$v$selection
    suppressMessages(r$v$save("first"))
    r$v$close()
    v2 <- suppressMessages(launch_lens(project = r$td, open = FALSE))
    on.exit(v2$close(discard = TRUE), add = TRUE)
    p2 <- lens_priv(v2)
    expect_error(v2$open_save("../first"), "no save '../first'")
    suppressMessages(v2$open_save("first"))
    expect_identical(p2$snapshot, r$priv$snapshot)
    expect_identical(p2$spat_unit, "bin")
    expect_setequal(names(p2$rule_set), c("r", "picked"))
    expect_setequal(v2$selection, sel)
    expect_identical(v2$selections(), data.frame(name = "top", rules = 1L, cells = 20L))
    expect_identical(p2$meta_names(), c("half", "score"))
    expect_identical(p2$meta_entry("score")$kind, "categorical")
    expect_identical(p2$col_types$score, "categorical")
    expect_identical(as.numeric(p2$meta_column("half") == "left")[1:2], c(1, 1))
    expect_setequal(names(p2$pushed), c("big", "small"))
    expect_true(file.exists(file.path(p2$work, sub("^work/", "", p2$pushed$big$data_url))))
    expect_identical(p2$config_json, '{"version":3,"colorBy":"half"}')
    expect_null(p2$unsaved_work())
    expect_output(print(v2), "save: +first\\.")
    # Nothing changed: another object can be shown without `discard`
    expect_no_error(suppressMessages(v2$open_project(r$td)))
})

test_that("saving needs an object in a project", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$save("x"), "nowhere to save")
    expect_error(v$saves(), "no project open")
})

test_that("several saves are deleted together, or none", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    suppressMessages(r$v$save("first"))
    suppressMessages(r$v$save("second"))
    left <- left_work(r)
    expect_error(r$v$delete_save(c("first", "nope")), "no save 'nope'")
    expect_error(r$v$delete_save(character()), "names of saves")
    expect_setequal(r$v$saves()$name, c("first", "second"))
    # From the page, as a JSON array
    lens_ask(r$v, op = "delete_save", path = r$td, name = list("first", basename(left)))
    expect_identical(r$v$saves()$name, "second")
    expect_false(dir.exists(left))
    expect_error(lens_ask(r$v, op = "delete_save", path = r$td, name = list(1, 2)), "names of saves")
    r$v$delete_save(c("second", "second"))
    expect_identical(nrow(r$v$saves()), 0L)
})

# ── Page asks ────────────────────────────────────────────────────────────────

test_that("the page saves, lists saves and opens one", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    res <- suppressMessages(lens_ask(r$v, op = "save", name = "first", description = "d"))
    expect_match(res$data$save, "^first\\.")
    res <- lens_ask(r$v, op = "save", name = "first")
    expect_identical(res$code, "exists")
    expect_match(suppressMessages(lens_ask(r$v, op = "save", name = "first", description = "d",
        overwrite = TRUE))$data$save,
        "^first\\.")
    expect_error(lens_ask(r$v, op = "save", name = "../x"), "letters, digits")
    r$v$save_selection("bottom", lens_cells(r$priv$cell_ids[880:900]))
    snaps <- lens_ask(r$v, op = "snapshots", path = r$td)$data
    s <- snaps$saves[[1L]]
    expect_identical(s[c("name", "kind", "description")], list(name = "first", kind = "save",
        description = "d"))
    expect_identical(s$snapshot, GiottoDisk::snapshotInfo(r$priv$project)$name[[1L]])
    expect_true(s$current)
    # This viewer's own work is not listed while it runs
    expect_length(snaps$saves, 1L)
    res <- lens_ask(r$v, op = "open_save", path = r$td, name = "first")
    expect_identical(res$code, "work")
    expect_match(res$error, "2 saved selections")
    res <- suppressMessages(lens_ask(r$v, op = "open_save", path = r$td, name = "first", discard = TRUE))
    expect_match(res$data$save, "^first\\.")
    expect_identical(r$v$selections()$name, "top")
})

test_that("the page deletes a save and work a viewer that ended left", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    tag <- suppressMessages(r$v$save("first"))
    left <- left_work(r)
    expect_identical(lens_ask(r$v, op = "delete_save", path = r$td, name = "first"), list(data = list()))
    expect_false(dir.exists(file.path(r$td, "lens", tag)))
    expect_null(r$priv$saved_tag)
    expect_true(GiottoDisk::snapshotInfo(r$priv$project)$keep[[1L]])
    lens_ask(r$v, op = "delete_save", path = r$td, name = basename(left))
    expect_false(dir.exists(left))
    expect_error(lens_ask(r$v, op = "delete_save", path = r$td, name = "../first"), "no save '../first'")
    expect_error(lens_ask(r$v, op = "delete_save", path = r$td, name = basename(r$priv$work)), "own work")
    expect_true(dir.exists(r$priv$work))
})

# ── Liveness ─────────────────────────────────────────────────────────────────

test_that("a running viewer's work cannot be opened or deleted by another", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    r$priv$write_state(force = TRUE)
    v2 <- suppressMessages(launch_lens(project = r$td, open = FALSE))
    on.exit(v2$close(discard = TRUE), add = TRUE)
    name <- basename(r$priv$work)
    expect_true(v2$saves(sessions = TRUE)$live[[1L]])
    expect_error(v2$open_save(name), "still running")
    expect_error(v2$delete_save(name), "still running")
    expect_error(r$v$open_save(name), "own work")
})

test_that("work left on another machine is live while its heartbeat is fresh", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    left <- left_work(r, host = "elsewhere.example", user = "someone")
    s <- r$v$saves(sessions = TRUE)
    s <- s[s$name == basename(left), ]
    expect_true(s$live)
    expect_identical(c(s$user, s$host), c("someone", "elsewhere.example"))
    expect_error(r$v$delete_save(basename(left)), "still running")
    expect_error(r$v$open_save(basename(left), discard = TRUE), "still running")
    Sys.setFileTime(file.path(left, "bundle.json"), Sys.time() - 5 * .heartbeat_s)
    expect_false(r$v$saves(sessions = TRUE)$live[r$v$saves(sessions = TRUE)$name == basename(left)])
    saves <- lens_ask(r$v, op = "snapshots", path = r$td)$data$saves
    mine <- saves[[which(vapply(saves, `[[`, "", "name") == basename(left))]]
    expect_identical(mine[c("user", "host", "mine")],
        list(user = "someone", host = "elsewhere.example", mine = FALSE))
    r$v$delete_save(basename(left))
    expect_false(dir.exists(left))
})

test_that("a running viewer rewrites bundle.json as a heartbeat", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    r$priv$write_state(force = TRUE)
    f <- file.path(r$priv$work, "bundle.json")
    updated <- jsonlite::fromJSON(f)$updated
    expect_false(r$priv$heartbeat())
    r$priv$beat_at <- 0
    Sys.setFileTime(f, Sys.time() - 5 * .heartbeat_s)
    expect_true(r$priv$heartbeat())
    expect_lt(as.numeric(difftime(Sys.time(), file.mtime(f), units = "secs")), 10)
    # The work did not change: `updated` stays when it was written
    expect_identical(jsonlite::fromJSON(f)$updated, updated)
})

# ── Cell mismatch and missing snapshot ───────────────────────────────────────

test_that("rules naming cells by position are left out when the cells differ", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    tag <- suppressMessages(r$v$save("first"))
    f <- file.path(r$td, "lens", tag, "bundle.json")
    b <- jsonlite::fromJSON(f, simplifyVector = FALSE)
    b$cells$md5 <- "0"
    writeLines(.bundle_json(b), f)
    expect_warning(suppressMessages(r$v$open_save("first", discard = TRUE)),
        paste("left out: metadata, rules naming cells by position, rules on columns left out,",
            "saved selections naming cells by position, panels linked to cells"))
    expect_identical(length(r$priv$rule_set), 0L)
    expect_identical(nrow(r$v$selections()), 0L)
    expect_identical(names(r$priv$pushed), "small")
    expect_null(r$priv$cached_meta)
})

test_that("a save whose snapshot was deleted does not open", {
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    suppressMessages(r$v$save("first"))
    f <- list.files(file.path(r$td, "lens"), "^first\\.", full.names = TRUE)
    b <- jsonlite::fromJSON(file.path(f, "bundle.json"), simplifyVector = FALSE)
    b$snapshot <- "gone.00000000"
    writeLines(.bundle_json(b), file.path(f, "bundle.json"))
    expect_error(r$v$open_save("first", discard = TRUE), "'gone.00000000' that 'first' was made on was deleted")
})

# ── Links and security ───────────────────────────────────────────────────────

test_that("a link in a save does not bring a file from elsewhere into the project", {
    skip_on_os("windows")
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    tag <- suppressMessages(r$v$save("first"))
    dir <- file.path(r$td, "lens", tag)
    secret <- tempfile("secret_")
    writeLines("secret", secret)
    on.exit(unlink(secret), add = TRUE)
    unlink(file.path(dir, "config.json"))
    file.symlink(secret, file.path(dir, "config.json"))
    col <- list.files(file.path(dir, "metadata"), full.names = TRUE)[[1L]]
    unlink(col)
    file.symlink(secret, col)
    expect_warning(suppressMessages(r$v$open_save("first", discard = TRUE)),
        "metadata files that could not be read")
    expect_identical(r$priv$meta_names(), "score")
    copied <- list.files(r$priv$work, recursive = TRUE, full.names = TRUE)
    expect_false(any(vapply(copied, function(f)
        length(grepRaw("secret", readBin(f, "raw", file.size(f)), fixed = TRUE)) > 0L, NA)))
    expect_null(r$priv$config_json)
    expect_error(suppressMessages(r$v$save("second")), NA)
})

test_that("a link in lens/ named like a bundle is neither opened nor deleted", {
    skip_on_os("windows")
    r <- bundle_viewer()
    on.exit(r$done(), add = TRUE)
    add_work(r)
    tag <- suppressMessages(r$v$save("first"))
    elsewhere <- tempfile("elsewhere_")
    dir.create(elsewhere)
    on.exit(unlink(elsewhere, recursive = TRUE), add = TRUE)
    b <- jsonlite::fromJSON(file.path(r$td, "lens", tag, "bundle.json"), simplifyVector = FALSE)
    b$name <- "evil"
    b$id <- "abcd1234"
    writeLines(.bundle_json(b), file.path(elsewhere, "bundle.json"))
    writeLines("keep", file.path(elsewhere, "precious.txt"))
    file.symlink(elsewhere, file.path(r$td, "lens", "evil.abcd1234"))
    expect_error(r$v$delete_save("evil"), "no save 'evil'")
    expect_error(r$v$open_save("evil", discard = TRUE), "no save 'evil'")
    expect_true(file.exists(file.path(elsewhere, "precious.txt")))
})
