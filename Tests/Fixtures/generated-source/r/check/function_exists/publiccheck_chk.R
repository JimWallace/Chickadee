# Test: Check
# Generated from notebook check "chk" kind=function_exists spec_hash=d40c23d7908c1bd9 — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

fn_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
fn <- tryCatch(get(fn_name, envir = student, inherits = FALSE),
               error = function(e) .ck_missing)
if (inherits(fn, "ck_missing")) {
    failed(paste0(
        "`", fn_name, "` is not defined in the student notebook.\n",
        "  expected: a function named `", fn_name, "`"))
}
if (!is.function(fn)) {
    failed(paste0(
        "`", fn_name, "` is defined but is not a function.\n",
        "  got: ", class(fn)[[1L]]))
}

# (no arity check; existence + callability only)

passed(paste0("`", fn_name, "` is defined and callable"))