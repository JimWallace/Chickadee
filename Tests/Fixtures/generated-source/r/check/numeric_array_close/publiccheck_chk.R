# Test: Check
# Generated from notebook check "chk" kind=numeric_array_close spec_hash=1ea518a2321aaf7a — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: a numeric vector of length 0"))
}
expected <- numeric(0)
rtol <- 1e-07
atol <- 0.0

actual_num <- suppressWarnings(as.numeric(actual))
if (length(actual_num) > 0L && all(is.na(actual_num)) && !all(is.na(actual))) {
    failed(paste0(
        "Variable `", variable_name, "` could not be read as a numeric vector.\n",
        "  got: ", class(actual)[[1L]]))
}

if (length(actual_num) != length(expected)) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong length.\n",
        "  expected: ", length(expected), " values\n",
        "  got:      ", length(actual_num), " values"))
}

# Mirrors numpy's allclose, including its equal_nan default: two NaNs
# agree, and two infinities of the same sign agree.  Non-finite
# positions are settled by those two rules alone and never by the
# tolerance — `rtol * Inf` is `Inf`, which would otherwise make every
# infinity match every other one.
both_nan <- is.nan(actual_num) & is.nan(expected)
both_inf <- is.infinite(actual_num) & is.infinite(expected) &
    (sign(actual_num) == sign(expected))
both_finite <- is.finite(actual_num) & is.finite(expected)
delta <- abs(actual_num - expected)
allowed <- atol + rtol * abs(expected)
ok <- both_nan | both_inf | (both_finite & delta <= allowed)
bad <- which(!ok)

if (length(bad) > 0L) {
    i <- bad[[1L]]
    failed(paste0(
        "Variable `", variable_name, "` is not close enough to expected.\n",
        "  position: ", i, "\n",
        "  expected: ", chickadee_format(expected[[i]]), "\n",
        "  got:      ", chickadee_format(actual_num[[i]]), "\n",
        "  tolerance: atol=", atol, " rtol=", rtol))
}

passed(paste0("`", variable_name, "` is close to expected (", length(expected), " values)"))