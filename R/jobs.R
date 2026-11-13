# Jobs: work the viewer starts in another process, so R's main thread keeps
# serving the page while it runs. One interface (LensViewer's private
# start_job() and cancel()); the backend is a local mizu pool of one worker,
# started by the first job and stopped with the viewer. Loading its packages
# makes that job several seconds slower than the next. A remote backend
# (mirai) goes behind the same interface. A job starts from the project path
# and a snapshot name, never a serialized object, and its result is applied
# on the main thread from the later loop.
#
# Job expressions call installed packages only: the worker loads them from
# the library, never a development copy of this one.

.job_pool <- function()
    mizu::mizu_pool(1L, launcher = mizu::mizu_launcher(stdout = FALSE, stderr = FALSE))

# A job's first step. arrow loads before anything that loads GDAL (terra), or
# the two collide over the 'file' filesystem scheme and reads from a store
# fail.
.job_prelude <- quote(
    for (p in c("arrow", "GiottoDisk", "GiottoClass")) requireNamespace(p, quietly = TRUE))

# The pull: snapshot `name` of the project at `path`, and one spatValues()
# call with a key per source (`key_args`: svkey() arguments, by label)
.pull_job <- bquote({
    .(.job_prelude)
    g <- suppressMessages(GiottoClass::loadGiotto(path, name = name, verbose = FALSE))
    keys <- lapply(key_args, function(a) do.call(GiottoClass::svkey, a))
    as.data.frame(suppressMessages(GiottoClass::spatValues(g, svkey = keys, verbose = FALSE)))
})
