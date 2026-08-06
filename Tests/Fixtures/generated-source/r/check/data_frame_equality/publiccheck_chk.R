# Test: Check
# Generated from notebook check "chk" kind=data_frame_equality spec_hash=b7b2276e1ec7ff12 — edit the check, not this file.
source("test_runtime.R")

student <- chickadee_load_student()

variable_name <- "df"

.ck_missing <- structure(list(), class = "ck_missing")
actual <- tryCatch(get(variable_name, envir = student, inherits = FALSE),
                   error = function(e) .ck_missing)
if (inherits(actual, "ck_missing")) {
    failed(paste0(
        "Variable `", variable_name, "` is not defined in the student notebook.\n",
        "  expected: a data frame equal to the expected data"))
}
if (!is.data.frame(actual)) {
    failed(paste0(
        "Variable `", variable_name, "` is not a data frame.\n",
        "  expected: a data frame equal to the expected data\n",
        "  got:      ", class(actual)[[1L]]))
}

expected <- read.csv("_expected_chk.csv",
                     stringsAsFactors = FALSE, check.names = FALSE)
rtol <- 1e-05
atol <- 1e-08

if (nrow(actual) != nrow(expected) || ncol(actual) != ncol(expected)) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong shape.\n",
        "  expected: ", nrow(expected), " rows x ", ncol(expected), " columns\n",
        "  got:      ", nrow(actual), " rows x ", ncol(actual), " columns"))
}

if (!all(names(actual) == names(expected))) {
    failed(paste0(
        "Variable `", variable_name, "` has the wrong columns.\n",
        "  expected: ", chickadee_format(names(expected)), "\n",
        "  got:      ", chickadee_format(names(actual))))
}

# Numeric columns compare within tolerance; everything else compares as
# text, so a factor and a character column holding the same labels agree.
for (col in names(expected)) {
    exp_col <- expected[[col]]
    got_col <- actual[[col]]
    if (is.numeric(exp_col) && is.numeric(got_col)) {
        delta <- abs(as.numeric(got_col) - as.numeric(exp_col))
        allowed <- atol + rtol * abs(as.numeric(exp_col))
        bad <- which(!is.na(delta) & delta > allowed)
        na_mismatch <- which(is.na(got_col) != is.na(exp_col))
        bad <- sort(unique(c(bad, na_mismatch)))
        if (length(bad) > 0L) {
            i <- bad[[1L]]
            failed(paste0(
                "Column `", col, "` differs from the expected data.\n",
                "  row:      ", i, "\n",
                "  expected: ", chickadee_format(exp_col[[i]]), "\n",
                "  got:      ", chickadee_format(got_col[[i]])))
        }
    } else {
        exp_chr <- as.character(exp_col)
        got_chr <- as.character(got_col)
        bad <- which(!(exp_chr == got_chr) | (is.na(exp_chr) != is.na(got_chr)))
        if (length(bad) > 0L) {
            i <- bad[[1L]]
            failed(paste0(
                "Column `", col, "` differs from the expected data.\n",
                "  row:      ", i, "\n",
                "  expected: ", chickadee_format(exp_chr[[i]]), "\n",
                "  got:      ", chickadee_format(got_chr[[i]])))
        }
    }
}

passed(paste0("`", variable_name, "` matches the expected data (",
              nrow(expected), " rows x ", ncol(expected), " columns)"))