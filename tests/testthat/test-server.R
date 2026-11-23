test_that(".parse_range handles the single-range forms", {
    expect_null(.parse_range(NULL, 100))
    expect_null(.parse_range("bytes=-", 100))
    expect_null(.parse_range("items=0-1", 100))
    expect_identical(.parse_range("bytes=0-0", 100), c(0, 0))
    expect_identical(.parse_range("bytes=10-", 100), c(10, 99))
    expect_identical(.parse_range("bytes=90-200", 100), c(90, 99))
    expect_identical(.parse_range("bytes=-10", 100), c(90, 99))
    expect_identical(.parse_range("bytes=100-120", 100), NA)
    expect_identical(.parse_range("bytes=5-2", 100), NA)
})

test_that(".origin_allowed accepts local and same-host origins only", {
    expect_true(.origin_allowed(NULL, "127.0.0.1:3000"))
    expect_true(.origin_allowed("http://127.0.0.1:3000", "127.0.0.1:3000"))
    expect_true(.origin_allowed("http://localhost:41234", "127.0.0.1:3000"))
    expect_true(.origin_allowed("https://rs.example.org", "rs.example.org"))
    expect_false(.origin_allowed("https://evil.example.com", "127.0.0.1:3000"))
    expect_false(.origin_allowed("null", "127.0.0.1:3000"))
    old_opt <- options(GiottoLens.allowed_origins = "proxy.example.org")
    on.exit(options(old_opt), add = TRUE)
    expect_true(.origin_allowed("https://proxy.example.org", "127.0.0.1:3000"))
})

test_that(".ws_allowed needs the token", {
    req <- list(PATH_INFO = "/lens/abc/ws", HTTP_HOST = "127.0.0.1:1")
    expect_true(.ws_allowed(req, "abc"))
    expect_false(.ws_allowed(req, "abd"))
    expect_false(.ws_allowed(list(PATH_INFO = "/lens/ws"), "abc"))
    expect_false(.ws_allowed(list(PATH_INFO = "/lens/abcd/ws"), "abc"))
})

test_that("without the Origin check the token alone admits a socket", {
    req <- list(PATH_INFO = "/lens/abc/ws", HTTP_HOST = "127.0.0.1:1",
        HTTP_ORIGIN = "https://rstudio.example.org")
    expect_false(.ws_allowed(req, "abc"))
    expect_true(.ws_allowed(req, "abc", check_origin = FALSE))
    expect_false(.ws_allowed(modifyList(req, list(PATH_INFO = "/lens/x/ws")), "abc", check_origin = FALSE))
})

test_that("a store with links leading out of it is not served by the static thread", {
    skip_on_os("windows")
    root <- tempfile("store")
    dir.create(file.path(root, "sub"), recursive = TRUE)
    on.exit(unlink(root, recursive = TRUE), add = TRUE)
    root <- normalizePath(root)
    writeBin(as.raw(1:10), file.path(root, "sub", "f.bin"))
    expect_false(.links_outside(root))
    file.symlink(file.path(root, "sub", "f.bin"), file.path(root, "inside.bin"))
    expect_false(.links_outside(root))
    secret <- tempfile("secret"); writeBin(as.raw(42), secret)
    on.exit(unlink(secret), add = TRUE)
    file.symlink(secret, file.path(root, "sub", "out.bin"))
    expect_true(.links_outside(root))

    app <- .lens_app(.viewer_dir(), tempdir(), lens_routes(list(m = root)), "tok", list())
    expect_true(app$staticPaths[["/lens/tok/d/sec/files/m"]]$options$exclude)
    # ...so files/ goes through .data_response, which checks real paths
    req <- function(path) list(PATH_INFO = path, REQUEST_METHOD = "GET")
    expect_identical(app$call(req("/lens/tok/d/sec/files/m/sub/f.bin"))$status, 200L)
    expect_identical(app$call(req("/lens/tok/d/sec/files/m/inside.bin"))$status, 200L)
    expect_identical(app$call(req("/lens/tok/d/sec/files/m/sub/out.bin"))$status, 404L)
    expect_identical(app$call(req("/lens/tok/d/sec/data/m/sub/out.bin"))$status, 404L)
})

test_that("the data is served under the data secret, and follows it when it changes", {
    root <- tempfile("mount")
    dir.create(root)
    on.exit(unlink(root, recursive = TRUE), add = TRUE)
    writeBin(as.raw(1:10), file.path(root, "f.bin"))
    routes <- lens_routes(list(m = root))
    app <- .lens_app(.viewer_dir(), tempdir(), routes, "tok", list())
    static <- function(p) !isTRUE(app$staticPaths[[p]]$options$exclude)
    expect_setequal(names(app$staticPaths), c("/lens/tok", "/lens/tok/d/sec",
        "/lens/tok/d/sec/session", "/lens/tok/d/sec/files/m"))
    # Only the bundle, session/ and a store's files/ come from the static thread
    expect_identical(vapply(names(app$staticPaths), static, NA, USE.NAMES = FALSE),
        names(app$staticPaths) != "/lens/tok/d/sec")
    req <- function(path) list(PATH_INFO = path, REQUEST_METHOD = "GET")
    expect_identical(app$call(req("/lens/tok/d/sec/data/m/f.bin"))$status, 200L)
    for (p in c("/lens/tok/data/m/f.bin", "/lens/tok/d/data/m/f.bin", "/lens/tok/d/other/data/m/f.bin",
                "/lens/tok/d/sec/../sec/data/m/f.bin", "/lens/tok/d/se/data/m/f.bin"))
        expect_identical(app$call(req(p))$status, 404L, info = p)
    routes$secret <- "new"
    expect_identical(app$call(req("/lens/tok/d/new/data/m/f.bin"))$status, 200L)
    expect_identical(app$call(req("/lens/tok/d/sec/data/m/f.bin"))$status, 404L)
    expect_identical(names(.data_paths("/lens/tok/d/new", tempdir(), routes$mounts)),
        c("/lens/tok/d/new", "/lens/tok/d/new/session", "/lens/tok/d/new/files/m"))
})

test_that(".data_response serves ranges and refuses paths outside a mount", {
    root <- tempfile("mount")
    dir.create(file.path(root, "sub"), recursive = TRUE)
    on.exit(unlink(root, recursive = TRUE), add = TRUE)
    writeBin(as.raw(0:99), file.path(root, "sub", "f.bin"))
    writeBin(as.raw(1), file.path(dirname(root), "outside.bin"))
    on.exit(unlink(file.path(dirname(root), "outside.bin")), add = TRUE)
    mounts <- list(m = normalizePath(root))
    req <- function(path, range = NULL, method = "GET")
        list(PATH_INFO = path, HTTP_RANGE = range, REQUEST_METHOD = method)

    r <- .data_response(req("/lens/tok/data/m/sub/f.bin", "bytes=10-19"), mounts, "/lens/tok")
    expect_identical(r$status, 206L)
    expect_identical(r$body, as.raw(10:19))
    expect_identical(r$headers[["Content-Range"]], "bytes 10-19/100")

    full <- .data_response(req("/lens/tok/data/m/sub/f.bin"), mounts, "/lens/tok")
    expect_identical(full$status, 200L)
    expect_identical(unname(full$body), normalizePath(file.path(root, "sub", "f.bin")))

    expect_identical(.data_response(req("/lens/tok/data/m/sub/f.bin", "bytes=200-"), mounts, "/lens/tok")$status, 416L)
    expect_identical(.data_response(req("/lens/tok/data/m/../outside.bin"), mounts, "/lens/tok")$status, 404L)
    expect_identical(.data_response(req("/lens/tok/data/m/%2e%2e/outside.bin"), mounts, "/lens/tok")$status, 404L)
    expect_identical(.data_response(req("/lens/tok/data/zz/sub/f.bin"), mounts, "/lens/tok")$status, 404L)
    expect_identical(.data_response(req("/lens/tok/data/m/sub"), mounts, "/lens/tok")$status, 404L)
    expect_identical(.data_response(req("/lens/tok/data/m/sub/f.bin", method = "POST"), mounts, "/lens/tok")$status, 405L)
    # Only under this launch's token
    expect_identical(.data_response(req("/lens/other/data/m/sub/f.bin"), mounts, "/lens/tok")$status, 404L)
    expect_identical(.data_response(req("/lens/data/m/sub/f.bin"), mounts, "/lens/tok")$status, 404L)
    # A NUL is a 404, not an R error
    expect_identical(.data_response(req("/lens/tok/data/m/sub/f.bin%00.txt"), mounts, "/lens/tok")$status, 404L)
})

test_that("a local build in viewer-dev is served while it is newer than the committed bundle", {
    pkg <- tempfile("pkg")
    on.exit(unlink(pkg, recursive = TRUE), add = TRUE)
    index <- function(d) file.path(pkg, d, "index.html")
    expect_error(.viewer_dir(pkg), "cannot find the viewer bundle")
    for (d in c("viewer", "viewer-dev")) {
        dir.create(file.path(pkg, d), recursive = TRUE)
        writeLines("<html></html>", index(d))
    }
    Sys.setFileTime(index("viewer"), Sys.time() - 60)
    expect_identical(.viewer_dir(pkg), file.path(pkg, "viewer-dev"))
    # A pull that updates the committed bundle makes it the newer one
    Sys.setFileTime(index("viewer"), Sys.time() + 60)
    expect_identical(.viewer_dir(pkg), file.path(pkg, "viewer"))
    unlink(file.path(pkg, "viewer"), recursive = TRUE)
    expect_identical(.viewer_dir(pkg), file.path(pkg, "viewer-dev"))
})
