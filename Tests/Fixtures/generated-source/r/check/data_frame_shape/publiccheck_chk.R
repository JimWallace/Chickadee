# Test: Check
# Generated from notebook check "chk" kind=data_frame_shape spec_hash=754da7a2a0fa49ee — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: a data frame with 3 rows and 2 columns"))
}
expected_rows <- 3
expected_cols <- 2

if (!is.data.frame(actual)) {
    failed(paste0(
        "Variable `", variable_name, "` is not a data frame.\n",
        "  expected: a data frame with 3 rows and 2 columns\n",
        "  got:      ", class(actual)[[1L]]))
}

actual_rows <- nrow(actual)
actual_cols <- ncol(actual)
if (actual_rows != expected_rows || actual_cols != expected_cols) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong shape.\n",
        "  expected: ", expected_rows, " rows x ", expected_cols, " columns\n",
        "  got:      ", actual_rows, " rows x ", actual_cols, " columns"))
}

passed(paste0("`", variable_name, "` has ", actual_rows, " rows and ", actual_cols, " columns"))