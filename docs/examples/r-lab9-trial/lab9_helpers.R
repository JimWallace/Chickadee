# HLTH 230 (R trial) — Lab 9 helper module.
#
# Base-R only: the Chickadee grading image ships `r-base` with no extra CRAN
# packages, so everything here uses functions from base / stats / utils /
# grDevices. This mirrors the Python lab9_helpers.py so the R lab behaves like
# the original:
#
#   load_data()                    -> the full cleaned NHANES adult table (data.frame)
#   build_cohort(seed, n = 1000)   -> a reproducible random sub-sample of that table
#   evaluate_model(features, data) -> held-out accuracy of a logistic-regression
#                                     hypertension classifier using `features`
#
# It also carries the plumbing the R autograder needs to load the student's
# submitted code. Unlike the browser/Python path there is no auto-imported
# `student_module` on the R worker path, so each test sources the submission
# itself via load_student() below. The pass/fail helpers (passed/failed/errored)
# come from test_runtime.R, which the runner injects next to this file.

FEATURES  <- c("age", "female", "bmi", "waist", "activity_min",
               "smoker", "sleep_hours", "cholesterol")
OUTCOME   <- "high_bp"
DATA_FILE <- "nhanes_bp.csv"

# Load the curated NHANES table and drop rows with any missing values.
load_data <- function() {
    df <- utils::read.csv(DATA_FILE, stringsAsFactors = FALSE)
    df <- df[stats::complete.cases(df), , drop = FALSE]
    rownames(df) <- NULL
    df
}

# Return YOUR personal cohort: a reproducible random sample of n adults.
build_cohort <- function(seed, n = 1000) {
    data <- load_data()
    n <- min(n, nrow(data))
    set.seed(as.integer(seed))
    idx <- sample.int(nrow(data), n)
    out <- data[idx, , drop = FALSE]
    rownames(out) <- NULL
    out
}

# Train a logistic-regression hypertension classifier on `data` using the given
# `features`, and return its accuracy on a held-out test set (0..1).
#
# A deterministic 75/25 split (every 4th row is held out for testing) keeps the
# score reproducible for everyone. Uses R's built-in glm() rather than a
# hand-rolled fit — showing off what base R gives you for free.
evaluate_model <- function(features, data) {
    features <- intersect(as.character(features), FEATURES)
    if (length(features) == 0L) stop("Pick at least one feature.")

    n <- nrow(data)
    test_mask <- ((seq_len(n) - 1L) %% 4L == 0L)   # rows 1, 5, 9, ... held out
    train <- data[!test_mask, , drop = FALSE]
    test  <- data[ test_mask, , drop = FALSE]

    form <- stats::as.formula(paste(OUTCOME, "~", paste(features, collapse = " + ")))
    fit  <- suppressWarnings(stats::glm(form, data = train, family = stats::binomial()))
    prob <- suppressWarnings(stats::predict(fit, newdata = test, type = "response"))
    preds <- as.integer(prob >= 0.5)
    mean(preds == test[[OUTCOME]])
}

# ---------------------------------------------------------------------------
# Autograder plumbing — locate and load the student's submitted R code.
#
# The R worker path has no auto-imported `student_module`, so each test script
# calls load_student() to get an environment holding the student's functions.
# We evaluate the submission expression-by-expression in a fresh environment so
# that (a) their top-level calls / plots don't clobber the test's variables, and
# (b) a runtime error in one top-level line (e.g. an unfinished TODO) doesn't
# stop their *function definitions* from loading.
# ---------------------------------------------------------------------------

# The one non-test, non-helper .R file in the working directory is the
# submission. During validation that file is solution.R (the reference answer
# key); during grading it is the student's extracted notebook.
.ck_find_student_file <- function() {
    rfiles  <- list.files(pattern = "\\.[Rr]$")
    skip    <- c("test_runtime.R", "lab9_helpers.R")
    is_test <- grepl("^(publictest|releasetest|secrettest|studenttest)", rfiles)
    cand    <- rfiles[!(rfiles %in% skip) & !is_test]
    if (length(cand) == 0L) return(NA_character_)
    if ("solution.R" %in% cand) return("solution.R")
    cand[[1L]]
}

load_student <- function() {
    f <- .ck_find_student_file()
    if (is.na(f)) errored("No R submission file was found to grade.")

    env <- new.env(parent = globalenv())   # helpers (this file) live in globalenv
    grDevices::pdf(NULL)                    # swallow any plot cells the notebook runs
    on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)

    exprs <- tryCatch(parse(file = f), error = function(e) NULL)
    if (is.null(exprs)) {
        errored(paste0("Your submission (", f, ") could not be parsed as R — check for a syntax error."))
    }
    # Evaluate each top-level statement independently: a broken TODO cell fails
    # in isolation, leaving the surrounding function definitions intact.
    for (ex in exprs) tryCatch(eval(ex, envir = env), error = function(e) invisible(NULL))
    env
}

# Fetch a named function the student was asked to write; a clear error if it is
# missing or was overwritten with a non-function.
require_student_fn <- function(env, name) {
    fn <- tryCatch(get(name, envir = env, inherits = FALSE), error = function(e) NULL)
    if (is.null(fn) || !is.function(fn)) {
        errored(sprintf("Your submission must define a function called `%s()`.", name))
    }
    fn
}
