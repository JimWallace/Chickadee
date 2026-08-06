# Test: Check
# Generated from notebook check "chk" kind=series_equality spec_hash=24c7f42fa3c4155d — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: a vector matching the expected values"))
}
# R has no Series: the analogue is a plain vector, and a one-column data
# frame is accepted too so a student who kept the column wrapped still
# passes.
if (is.data.frame(actual)) {
    if (ncol(actual) != 1L) {
        failed(paste0(
            "Variable `", variable_name, "` should be a single vector (or a one-column frame).\n",
            "  got:      a data frame with ", ncol(actual), " columns"))
    }
    actual <- actual[[1L]]
}
if (!is.atomic(actual)) {
    failed(paste0(
        "Variable `", variable_name, "` should be a vector.\n",
        "  got:      ", class(actual)[[1L]]))
}

expected_frame <- read.csv("_expected_chk.csv",
                           stringsAsFactors = FALSE, check.names = FALSE)
expected <- expected_frame[[1L]]
rtol <- 1e-05
atol <- 1e-08

if (length(actual) != length(expected)) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong length.\n",
        "  expected: ", length(expected), " values\n",
        "  got:      ", length(actual), " values"))
}

if (is.numeric(expected) && is.numeric(actual)) {
    delta <- abs(as.numeric(actual) - as.numeric(expected))
    allowed <- atol + rtol * abs(as.numeric(expected))
    bad <- which(!is.na(delta) & delta > allowed)
    bad <- sort(unique(c(bad, which(is.na(actual) != is.na(expected)))))
} else {
    exp_chr <- as.character(expected)
    got_chr <- as.character(actual)
    bad <- which(!(exp_chr == got_chr) | (is.na(exp_chr) != is.na(got_chr)))
}

if (length(bad) > 0L) {
    i <- bad[[1L]]
    failed(paste0(
        "Variable `", variable_name, "` differs from the expected values.\n",
        "  position: ", i, "\n",
        "  expected: ", chickadee_format(expected[[i]]), "\n",
        "  got:      ", chickadee_format(actual[[i]])))
}

passed(paste0("`", variable_name, "` matches the expected ", length(expected), " values"))