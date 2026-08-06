# Test: v
# Generated from pattern family "Family" [fam] spec_hash=3e7d072c983cd304 — edit the family, not this file.
source("test_runtime.R")

variable_name <- "total"
expected      <- 3

student <- chickadee_load_student()
.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)

if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined\n",
        "  expected: ", chickadee_format(expected)))
}

if (!chickadee_equal(actual, expected)) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong value\n",
        "  expected: ", chickadee_format(expected), "\n",
        "  got:      ", chickadee_format(actual)))
}

passed(paste0(variable_name, " == ", chickadee_format(actual)))