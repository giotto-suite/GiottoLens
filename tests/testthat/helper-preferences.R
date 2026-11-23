# Tests read and write a preferences file of their own, never the user's
options(GiottoLens.preferences_file = file.path(tempdir(), "lens-test-preferences.json"))

# A preferences file of the test's own, removed when it ends
local_pref_file <- function(env = parent.frame()) {
    f <- tempfile(fileext = ".json")
    old <- options(GiottoLens.preferences_file = f)
    withr::defer({ options(old); unlink(f) }, envir = env)
    f
}
