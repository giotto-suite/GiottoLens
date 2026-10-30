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

test_that("tokens come from the OS random source, not R's RNG", {
    set.seed(1); a <- .rand_id(24L); state <- .Random.seed
    set.seed(1); b <- .rand_id(24L)
    expect_false(identical(a, b))
    expect_identical(.Random.seed, state)            # the user's RNG is untouched
    expect_match(a, "^[A-Za-z0-9]{24}$")
})

test_that("browser text reaches the console without control characters", {
    ctl <- function(...) intToUtf8(c(...), multiple = TRUE)
    x <- paste0("ok", ctl(27), "[31m red", ctl(7), "\n\tcaf\u00e9", ctl(0x9b))
    expect_identical(.console_text(x), "ok[31m red\n\tcaf\u00e9")
    expect_identical(.console_text(NULL), "")
    expect_identical(.console_text(list("a", 1)), "a 1")
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

    app <- .lens_app(.viewer_dir(), tempdir(), list(m = root), "tok", list())
    expect_true(app$staticPaths[["/lens/tok/files/m"]]$options$exclude)
    # ...so files/ goes through .data_response, which checks real paths
    req <- function(path) list(PATH_INFO = path, REQUEST_METHOD = "GET")
    expect_identical(app$call(req("/lens/tok/files/m/sub/f.bin"))$status, 200L)
    expect_identical(app$call(req("/lens/tok/files/m/inside.bin"))$status, 200L)
    expect_identical(app$call(req("/lens/tok/files/m/sub/out.bin"))$status, 404L)
    expect_identical(app$call(req("/lens/tok/data/m/sub/out.bin"))$status, 404L)
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
