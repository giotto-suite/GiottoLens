# Regions are named sets of cells R holds for the object shown; comparing two
# runs Giotto::findScranMarkers() as a job (R/regions.R, adr/0020).

# The bins fixture with normalized expression: g1 high in the left half
de_object <- local({
    out <- NULL
    function() {
        if (!is.null(out)) return(out)
        bx <- lens_bins_fixture()
        ids <- bx$xy$cell_ID
        left <- bx$meta$half[match(ids, bx$meta$cell_ID)] == "left"
        set.seed(1)
        m <- rbind(g1 = ifelse(left, 3, 0.5) + stats::runif(length(ids)),
            g2 = 1 + stats::runif(length(ids)))
        colnames(m) <- ids
        g <- suppressMessages(suppressWarnings(GiottoClass::setGiotto(bx$mem,
            GiottoClass::createExprObj(m, spat_unit = "bin", feat_type = "rna",
                name = "normalized"), verbose = FALSE)))
        out <<- list(g = g, left = ids[left], right = ids[!left])
    }
})
de_viewer <- function() {
    d <- de_object()
    td <- tempfile("lensproj_")
    v <- suppressMessages(launch_lens(d$g, spat_unit = "bin", feat_type = NULL, open = FALSE,
        project = td))
    list(v = v, d = d, priv = get("private", v$.__enclos_env__),
        done = function() { v$close(); unlink(td, recursive = TRUE) })
}

test_that("regions are saved, listed, selected and removed", {
    fx <- lens_fixture()
    v <- launch_lens(fx$gpoints, fx$gpolygons, open = FALSE)
    on.exit(v$close(), add = TRUE)
    expect_error(v$save_region("a"), "no cells to save")
    v$set_selection(c("cell_001", "cell_002", "cell_003"))
    expect_identical(v$save_region("a"), c("cell_001", "cell_002", "cell_003"))
    expect_warning(v$save_region(" b ", c("cell_010", "nope")), "1 ID\\(s\\) are not cells")
    expect_identical(v$regions(), data.frame(name = c("a", "b"), cells = c(3L, 1L)))
    expect_identical(v$regions("b"), "cell_010")
    v$select_region("b")
    expect_identical(v$selection, "cell_010")
    v$remove_region("a")
    expect_identical(v$regions()$name, "b")
    expect_error(v$regions("a"), "no region 'a'; regions: b")
    expect_error(v$save_region(""), "non-empty string")

    # Comparing needs two regions and an object with expression
    v$save_region("c", c("cell_003", "cell_004"))
    expect_error(v$compare_regions("b", "b"), "the same region")
    expect_error(v$compare_regions("b", "z"), "no region 'z'")
    expect_error(v$compare_regions("b", "c"), "shows layers, not a giotto object")
    expect_identical(nrow(v$de_results()), 0L)
})

test_that("a comparison reads normalized values, and regions go with the object", {
    fx <- lens_bins_fixture()
    v <- suppressMessages(launch_lens(fx$g, spat_unit = "bin", feat_type = NULL, open = FALSE))
    on.exit(v$close(), add = TRUE)
    v$save_region("left", fx$xy$cell_ID[1:10])
    expect_error(v$compare_regions("left"), "no 'normalized' expression; normalize .*available: raw")
    expect_error(v$compare_regions("left", values = "nope"), "no 'nope' expression; available: raw")
    expect_error(suppressMessages(v$set_object(fx$g, spat_unit = "bin", feat_type = NULL)), "1 region")
    suppressMessages(v$set_object(fx$g, spat_unit = "bin", feat_type = NULL, discard = TRUE))
    expect_identical(nrow(v$regions()), 0L)
})

test_that("regions are compared in a job, docked as a volcano plot", {
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    v$save_region("left", dv$d$left)
    v$save_region("right", dv$d$right)
    tab <- suppressMessages(v$compare_regions("left", "right"))
    expect_named(tab, c("gene", "logFC", "p_value", "FDR"))
    expect_identical(tab$gene[1L], "g1")
    expect_gt(tab$logFC[1L], 0)
    expect_false(is.unsorted(tab$FDR, na.rm = TRUE))

    # The same test run directly
    g <- dv$d$g
    ids <- GiottoClass::spatIDs(g, spat_unit = "bin")
    ref <- GiottoClass::addCellMetadata(g, spat_unit = "bin", feat_type = "rna",
        new_metadata = data.frame(cell_ID = ids, grp = ifelse(ids %in% dv$d$left, "l", "r")),
        by_column = TRUE, column_cell_ID = "cell_ID")
    ref <- suppressMessages(Giotto::findScranMarkers(ref, spat_unit = "bin", feat_type = "rna",
        expression_values = "normalized", cluster_column = "grp", group_1 = "l", group_2 = "r",
        verbose = FALSE))
    ref <- as.data.frame(Find(function(d) d$cluster[1L] == "l", ref))
    m <- match(tab$gene, ref$feats)
    expect_equal(tab$logFC, ref$summary.logFC[m])
    expect_equal(tab$FDR, ref$FDR[m])

    res <- v$de_results()
    expect_identical(res$id, "de-1")
    expect_identical(res$cells_a, length(dv$d$left))
    expect_identical(res$values, "normalized")
    expect_true("de-1" %in% v$panels()$id)
    expect_identical(v$de_results("de-1"), tab)

    # Against every other cell, without waiting: the job's id
    id <- v$compare_regions("left", wait = FALSE)
    expect_identical(v$jobs()$label, "DE left vs rest")
    expect_identical(v$jobs()$id, id)
    expect_true(suppressMessages(pump_until(function() nrow(v$de_results()) == 2L, timeout = 60)))
    expect_identical(v$de_results()$b, c("right", "rest"))
})

test_that("the page acts on regions through the `region` ask, and a volcano pick colors its cells", {
    skip_if_not_installed("websocket")
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    a <- ws_client(ws_url(v), load = dv$priv$load_seq)
    on.exit(a$ws$close(), add = TRUE, after = FALSE)
    expect_true(pump_until(function() v$connected()))
    of <- function(type) Filter(function(m) identical(m$type, type), a$state$msgs)
    expect_true(pump_until(function() length(of("regions")) > 0L))
    answer <- function(id) {
        hit <- NULL
        pump_until(function() {
            for (m in of("answer")) if (identical(m$data$id, id)) hit <<- m$data
            !is.null(hit)
        }, timeout = 60)
        hit
    }
    send <- function(id, ...) a$ws$send(jsonlite::toJSON(list(type = "ask", id = id,
        data = list(op = "region", ...)), auto_unbox = TRUE))

    v$set_selection(dv$d$left)
    send("1", action = "save", name = "left")
    expect_identical(answer("1")$data$cells, length(dv$d$left))
    expect_true(isTRUE(utils::tail(of("regions"), 1L)[[1L]]$data$open))
    v$set_selection(character())
    send("2", action = "save", name = "empty")
    expect_match(answer("2")$error, "no cells to save")
    send("3", action = "compare", a = "left", b = "", ref = "p1")
    r <- suppressMessages(answer("3"))
    expect_identical(r$data$id, "de-1")
    expect_true(any(vapply(of("job"), function(m) identical(m$data$ref, "p1"), NA)))

    # A click on g1 in the volcano plot: that page colours its cells by it
    a$ws$send(jsonlite::toJSON(list(type = "panel_pick", data = list(id = "de-1",
        value = list(gene = list("g1")))), auto_unbox = TRUE))
    key <- .item_key("expression", "rna", "g1", name = "normalized")
    expect_true(pump_until(function() any(vapply(of("set_color_by"), function(m)
        identical(m$data$column, key), NA)), timeout = 60))
    hit <- Find(function(m) identical(m$data$column, key), of("set_color_by"))
    expect_match(hit$data$item$url, "^session/items/")
    expect_false("g1" %in% dv$priv$meta_names())
})

test_that("the Regions panel saves the selection and compares, and a volcano pick colors the cells", {
    skip_if_not_installed("Giotto")
    skip_if_not_installed("scran")
    dv <- de_viewer()
    on.exit(dv$done(), add = TRUE)
    v <- dv$v
    br <- lens_browser(v$url)
    on.exit(br$close(), add = TRUE)
    expect_true(browser_wait(br, "window.__giottolens?.state.cells?.n === 900"))
    expect_true(pump_until(function() v$connected()))
    q <- function(sel) sprintf("document.querySelector('[data-panel=regions] %s')", sel)

    # A region saved from R brings the panel forward
    v$save_region("right", dv$d$right)
    expect_true(browser_wait(br, sprintf("!!%s", q(".rg-item[data-region=right]"))))

    # The page saves the selection under the name typed
    v$set_selection(dv$d$left)
    expect_true(browser_wait(br, sprintf("!%s.disabled", q(".rg-save"))))
    br$js(sprintf("(() => { %s.value = 'left'; %s.click(); })()", q(".rg-name"), q(".rg-save")))
    expect_true(pump_until(function() setequal(v$regions()$name, c("left", "right"))))
    expect_identical(length(v$regions("left")), length(dv$d$left))

    # Compare left vs right, reading the normalized values
    expect_true(browser_wait(br, sprintf("%s.value === 'normalized'", q(".rg-values"))))
    br$js(sprintf("(() => { const a = %s; a.value = 'left'; a.dispatchEvent(new Event('change'));
        const b = %s; b.value = 'right'; b.dispatchEvent(new Event('change')); %s.click(); })()",
        q(".rg-a"), q(".rg-b"), q(".rg-compare")))
    expect_true(suppressMessages(pump_until(function() nrow(v$de_results()) == 1L, timeout = 60)))
    expect_true(browser_wait(br, sprintf("%s.textContent === 'left vs right: done'", q(".rg-status"))))
    expect_true(browser_wait(br, "!!document.querySelector('[data-panel=de-1] canvas')"))

    # A gene picked in the volcano plot colors the cells by its item key
    key <- .item_key("expression", "rna", "g1", name = "normalized")
    br$js("(() => { const v = window.__giottolens.panel('de-1').view;
        return v.signal('pick_tuple', { unit: 'layer_0', fields: v.signal('pick_tuple_fields'),
            values: ['g1'] }).runAsync().then(() => true); })()")
    expect_true(browser_wait(br, sprintf("window.__giottolens.store.getState().colorBy === '%s'", key)))
    expect_true(browser_wait(br, "window.__giottolens.state.colorLegend?.type === 'continuous'"))
    expect_false("g1" %in% dv$priv$meta_names())

    # Genes share one scale: set for one, it stays for the next
    v$set_color_scale(style = "sequential", preset = "magma", limits = c(0, 2))
    v$color_by(.item_key("expression", "rna", "g2", name = "normalized"))
    lg <- br$js("(() => { const l = window.__giottolens.state.colorLegend;
        return { style: l.style, preset: l.scale.preset, lo: l.lo, hi: l.hi }; })()")
    expect_identical(lg, list(style = "sequential", preset = "magma", lo = 0L, hi = 2L))

    # Dragging the high handle on the bar to its middle moves the high end only
    pt <- br$js("(() => { const h = document.querySelector('.scale-handle[data-handle=hi]').getBoundingClientRect();
        const b = document.querySelector('.scale-bar').getBoundingClientRect();
        return [h.left + h.width / 2, h.top + h.height / 2, b.left + b.width / 2]; })()")
    mouse <- function(type, x, buttons) br$session$Input$dispatchMouseEvent(type = type, x = x,
        y = pt[[2]], button = "left", buttons = buttons, clickCount = 1L)
    mouse("mousePressed", pt[[1]], 1L)
    mouse("mouseMoved", (pt[[1]] + pt[[3]]) / 2, 1L)
    mouse("mouseMoved", pt[[3]], 1L)
    mouse("mouseReleased", pt[[3]], 0L)
    expect_true(browser_wait(br, "(() => { const l = window.__giottolens.state.colorLegend;
        return l.lo === 0 && Math.abs(l.hi - (l.min + l.max) / 2) < 0.02 * (l.max - l.min); })()", 10))
    sc <- v$state()$config$colorScales[["@expression"]]
    expect_equal(unlist(sc$limits)[1L], 0)
    expect_identical(br$errors(), character())
})
