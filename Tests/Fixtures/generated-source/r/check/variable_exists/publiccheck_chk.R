# Test: Check
# Generated from notebook check "chk" kind=variable_exists spec_hash=1198d01d1fe85b02 — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: a variable named `df`"))
}

# (no type check; existence only)

passed(paste0("`", variable_name, "` is defined"))