# Test: Check
# Generated from notebook check "chk" kind=data_frame_columns spec_hash=099de8998944375d — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: exactly these columns, in order"))
}
expected_cols <- c("a", "b")

if (!is.data.frame(actual)) {
    failed(paste0(
        "Variable `", variable_name, "` is not a data frame.\n",
        "  expected: exactly these columns, in order\n",
        "  got:      ", class(actual)[[1L]]))
}

actual_cols <- names(actual)
if (is.null(actual_cols)) actual_cols <- character(0)

if (length(actual_cols) != length(expected_cols) || !all(actual_cols == expected_cols)) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong columns.\n",
        "  expected: ", chickadee_format(expected_cols), " (exact, in order)\n",
        "  got:      ", chickadee_format(actual_cols)))
}

passed(paste0("`", variable_name, "` has the expected columns"))