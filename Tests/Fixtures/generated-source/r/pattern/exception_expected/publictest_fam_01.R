# Test: e
# Generated from pattern family "Family" [fam] spec_hash=af181e8a5562a736 — edit the family, not this file.
source("test_runtime.R")

x <- -1

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

err <- NULL
result <- withCallingHandlers(
    tryCatch(target(x), error = function(e) { err <<- e; NULL }),
    warning = function(w) invokeRestart("muffleWarning")
)

if (is.null(err)) {
    failed(paste0(
        "expected an error, but the call succeeded\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  got:      ", chickadee_format(result)))
}

    wanted <- "ValueError"
    classes <- paste(class(err), collapse = ", ")
    hit <- any(grepl(wanted, class(err), fixed = TRUE)) ||
        grepl(tolower(wanted), tolower(conditionMessage(err)), fixed = TRUE)
    if (!hit) {
        failed(paste0(
            "wrong error raised\n",
            "  input:    ", "x=", chickadee_format(x), "\n",
            "  expected: an error matching ", wanted, "\n",
            "  got:      ", classes, ": ", conditionMessage(err)))
    }

passed(paste0("Raised ", class(err)[[1L]], " as expected"))