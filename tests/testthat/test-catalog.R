# The catalog lists what the object shown can pull; pull() adds it to the
# viewer's metadata through one spatValues() call (R/catalog.R).

# The bins fixture with a second expression matrix (same features), a UMAP
# and a spatial enrichment, in memory
catalog_object <- local({
    g <- NULL
    function() {
        if (!is.null(g)) return(g)
        bx <- lens_bins_fixture()
        sw <- function(...) suppressMessages(suppressWarnings(...))
        ids <- bx$xy$cell_ID
        m <- matrix(rep(c(1, 0, 0, 1), length.out = 2L * length(ids)), 2L,
            dimnames = list(c("g1", "g2"), ids))
        x <- sw(GiottoClass::setGiotto(bx$mem, GiottoClass::createExprObj(log1p(m),
            spat_unit = "bin", feat_type = "rna", name = "normalized"), verbose = FALSE))
        dm <- matrix(seq_len(2L * length(ids)) / 10, ncol = 2L,
            dimnames = list(ids, c("Dim.1", "Dim.2")))
        x <- sw(GiottoClass::setGiotto(x, GiottoClass::createDimObj(dm, spat_unit = "bin",
            feat_type = "rna", method = "umap", name = "umap"), verbose = FALSE))
        enr <- data.frame(cell_ID = ids, T = seq_along(ids) / length(ids))
        x <- sw(GiottoClass::setGiotto(x, GiottoClass::createSpatEnrObj(enr, spat_unit = "bin",
            feat_type = "rna", name = "PAGE", method = "PAGE"), verbose = FALSE))
        g <<- x
        g
    }
})

catalog_viewer <- function() {
    td <- tempfile("lensproj_")
    v <- launch_lens(catalog_object(), spat_unit = "bin", feat_type = NULL, open = FALSE,
        project = td)
    list(v = v, priv = get("private", v$.__enclos_env__),
        done = function() { v$close(); unlink(td, recursive = TRUE) })
}

test_that("the catalog lists each source's names, and the page's copy shares repeats", {
    cat <- .lens_catalog(catalog_object(), "bin")
    got <- vapply(cat$sources, function(s) paste(s$slot, s$name %||% "-"), "")
    expect_setequal(got, c("cell_metadata -", "expression raw", "expression normalized",
        "spatial_enrichment PAGE", "dimension_reduction umap"))
    meta <- Find(function(s) s$slot == "cell_metadata", cat$sources)
    expect_identical(meta$items, c("array_row", "array_col", "half"))
    dr <- Find(function(s) s$slot == "dimension_reduction", cat$sources)
    expect_identical(dr$method, "umap")
    expect_identical(dr$items, c("Dim.1", "Dim.2"))

    p <- .catalog_payload(cat)
    ex <- Filter(function(s) s$slot == "expression", p$sources)
    expect_identical(unlist(ex[[1]]$items), c("g1", "g2"))
    expect_identical(ex[[2]]$same_as, ex[[1]]$id)
    expect_null(ex[[2]]$items)

    tbl <- .catalog_table(cat)
    expect_identical(names(tbl), c("source", "slot", "feat_type", "name", "item", "key"))
    expect_identical(nrow(tbl), 3L + 2L + 2L + 1L + 2L)
})

test_that("items are picked by name or by catalog row, with their types", {
    cat <- .lens_catalog(catalog_object(), "bin")
    tbl <- .catalog_table(cat)
    it <- .pull_items(cat, c("half", "T"), types = list(T = "factor"))
    expect_identical(it$item, c("half", "T"))
    expect_identical(it$type, c(NA, "categorical"))
    expect_error(.pull_items(cat, "g1"), "in more than one source: g1")
    expect_error(.pull_items(cat, c("half", "nope")), "not in the catalog: nope")
    rows <- tbl[tbl$item == "g1", ]
    rows$type <- c("auto", "numeric")
    it <- .pull_items(cat, rows)
    expect_identical(it$type, c(NA, "continuous"))
    expect_error(.pull_items(cat, data.frame(source = 1L, item = "g1")), "not in the catalog")
    expect_error(.pull_items(cat, list("half")), "item names or rows")
    expect_error(.pull_items(cat, c("half"), types = list(half = "blue")), "unknown column type")
})

test_that("a plan names repeated items by source and dim reduction axes by reduction", {
    cat <- .lens_catalog(catalog_object(), "bin")
    tbl <- .catalog_table(cat)
    pick <- tbl[tbl$item %in% c("g1", "Dim.2", "half"), ]
    plan <- .pull_plan(cat, .pull_items(cat, pick))
    expect_setequal(names(plan$keys), c("meta", "raw", "normalized", "umap"))
    expect_true(all(vapply(plan$keys, methods::is, NA, "svkey")))
    expect_setequal(plan$cols$column, c("half", "raw_g1", "normalized_g1", "umap_2"))
    vals <- suppressMessages(GiottoClass::spatValues(catalog_object(), svkey = plan$keys,
        verbose = FALSE))
    expect_true(all(plan$cols$result %in% names(vals)))
})

test_that("item keys encode as the page does and name one catalog item", {
    # The same key is checked in inst/viewer-src/test/items.test.ts
    key <- "@expression/rna/normalized//CD3E%2F%CE%B1%20b"
    expect_identical(.item_key("expression", "rna", "CD3E/\u03b1 b", name = "normalized"), key)
    ref <- .parse_item_key(key, "t")
    expect_identical(ref$item, "CD3E/\u03b1 b")
    expect_identical(ref$name, "normalized")
    expect_null(ref$method)
    dr <- .item_key("dimension_reduction", "rna", "Dim.1", name = "umap", method = "umap")
    expect_identical(.parse_item_key(dr, "t")[c("slot", "method", "item")],
        list(slot = "dimension_reduction", method = "umap", item = "Dim.1"))
    expect_error(.parse_item_key("half", "t"), "not an item key")
    expect_error(.parse_item_key("@expression/rna/raw/g1", "t"), "not an item key")
    expect_error(.parse_item_key("@counts/rna/raw//g1", "t"), "not an item key")

    cat <- .lens_catalog(catalog_object(), "bin")
    tbl <- .catalog_table(cat)
    expect_identical(tbl$key, .item_keys(cat, tbl))
    s <- .catalog_source_for(cat, .parse_item_key(tbl$key[tbl$item == "Dim.2"], "t"), "t")
    expect_identical(s$slot, "dimension_reduction")
    expect_error(.catalog_source_for(cat, .parse_item_key(
        .item_key("expression", "rna", "nope", name = "raw"), "t"), "t"), "has no 'nope'")
})

test_that("an item is read on its own into items/, never into the metadata", {
    cv <- catalog_viewer()
    on.exit(cv$done(), add = TRUE)
    priv <- cv$priv
    tbl <- cv$v$catalog()
    key <- tbl$key[tbl$item == "g1" & tbl$name %in% "normalized"]
    e <- priv$read_item(key, "t")
    expect_identical(e$name, key)
    expect_identical(e$kind, "continuous")
    expect_match(e$url, "^session/items/")
    expect_true(file.exists(file.path(priv$items_dir(), basename(e$url))))
    expect_equal(.read_meta_column(priv$items_dir(), e),
        GiottoClass::getExpression(catalog_object(), spat_unit = "bin", feat_type = "rna",
            values = "normalized", output = "matrix")["g1", priv$cell_ids], ignore_attr = TRUE)
    expect_false("g1" %in% priv$meta_names())
    # Read once per object
    expect_identical(priv$read_item(key, "t"), e)
    half <- priv$read_item(tbl$key[tbl$item == "half"], "t")
    expect_identical(half$kind, "categorical")
    expect_error(priv$read_item(.item_key("expression", "rna", "nope", name = "raw"), "t"),
        "has no 'nope'")
    # The object's items go with it
    priv$clear_object()
    expect_length(priv$item_files, 0L)
    expect_length(list.files(priv$items_dir()), 0L)
})

test_that("pull() adds columns to the metadata shown and replaces one of the same name", {
    cv <- catalog_viewer()
    on.exit(cv$done(), add = TRUE)
    v <- cv$v
    priv <- cv$priv
    kind <- function(name) priv$meta_entry(name)$kind
    expect_message(v$pull("half"), "pulled 1 column\\(s\\): half")
    tbl <- v$catalog()
    expect_message(v$pull(tbl[tbl$item %in% c("Dim.1", "T") | tbl$name %in% "raw", ],
        types = list(T = "categorical")), "pulled 4")
    expect_setequal(priv$meta_names(), c("half", "umap_1", "T", "g1", "g2"))
    expect_identical(kind("T"), "categorical")
    expect_true(is.numeric(priv$meta_values$T))
    expect_equal(priv$meta_column("umap_1"),
        GiottoClass::getDimReduction(catalog_object(), spat_unit = "bin", feat_type = "rna",
            reduction_method = "umap", name = "umap", output = "matrix")[priv$cell_ids, 1],
        ignore_attr = TRUE)
    files <- list.files(priv$meta_dir())
    expect_true(all(basename(vapply(priv$cached_meta$columns, `[[`, "", "url")) %in% files))

    # The same name again replaces it where it was, and drops rules on it
    at <- match("T", priv$meta_names())
    priv$rule_set <- list(meta = list(kind = "categories", space = "T",
        params = list(values = list("0.5"))))
    suppressMessages(v$pull(tbl[tbl$item == "T", ]))
    expect_identical(kind("T"), "continuous")
    expect_null(priv$meta_values$T)
    expect_length(priv$rule_set, 0L)
    expect_identical(match("T", priv$meta_names()), at)

    # push_metadata() still replaces the whole set
    suppressMessages(v$push_metadata(catalog_object(), spat_unit = "bin", cols = "half"))
    expect_identical(priv$meta_names(), "half")
})

test_that("only an object can be pulled from, and a load clears its catalog", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$catalog(), "shows layers, not a giotto object")
    expect_error(v$pull("score"), "shows layers, not a giotto object")
    expect_null(jsonlite::read_json(file.path(get("private", v$.__enclos_env__)$session,
        "manifest.json"))$catalog)
})

test_that("the page asks for the catalog and pulls, from the current object only", {
    testthat::skip_if_not_installed("websocket")
    cv <- catalog_viewer()
    on.exit(cv$done(), add = TRUE)
    v <- cv$v
    expect_true(jsonlite::read_json(file.path(cv$priv$session, "manifest.json"))$catalog)
    got <- function(cl, type) any(vapply(cl$state$msgs, function(m) m$type == type, NA))
    # Once R has its `ready`: the socket opens before the client says it
    a <- ws_client(ws_url(v), load = cv$priv$load_seq)
    on.exit(a$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() got(a, "restore")))
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

    send("1", op = "catalog")
    r <- answer("1")$data
    expect_identical(r$spat_unit, "bin")
    meta <- Find(function(s) s$slot == "cell_metadata", r$sources)
    send("2", op = "pull", keys = list(list(source = meta$id, items = list("array_row", "half"),
        types = list("categorical", "auto"))))
    r <- suppressMessages(answer("2"))
    expect_identical(unlist(r$data$columns), c("array_row", "half"))
    expect_identical(cv$priv$meta_entry("array_row")$kind, "categorical")
    send("3", op = "pull", keys = list(list(source = meta$id, items = list("nope"))))
    expect_match(answer("3")$error, "not in the catalog: nope")
    key <- .item_key("expression", "rna", "g2", name = "raw")
    send("5", op = "item", key = key)
    r <- answer("5")$data
    expect_identical(r$name, key)
    expect_match(r$url, "^session/items/")
    expect_false("g2" %in% cv$priv$meta_names())
    send("6", op = "item", key = "g2")
    expect_match(answer("6")$error, "not an item key")

    # A page still on an earlier load is refused
    b <- ws_client(ws_url(v), load = cv$priv$load_seq - 1L)
    on.exit(b$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() got(b, "reload")))
    b$ws$send(jsonlite::toJSON(list(type = "ask", id = "4", data = list(op = "catalog")),
        auto_unbox = TRUE))
    hit <- NULL
    pump_until(function() {
        for (m in b$state$msgs) if (m$type == "answer") hit <<- m$data
        !is.null(hit)
    })
    expect_identical(hit$code, "stale")
})
