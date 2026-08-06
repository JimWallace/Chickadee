# Test: s
# Generated from pattern family "Family" [fam] spec_hash=fc8371b5e923b61d — edit the family, not this file.
source("test_runtime.R")

x <- 1

expected_output <- "hello"

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

.ck_normalize <- function(text) {
    lines <- strsplit(as.character(text), "\n", fixed = TRUE)[[1L]]
    lines <- sub("[[:space:]]+$", "", lines)
    while (length(lines) > 0L && !nzchar(lines[[length(lines)]])) {
        lines <- lines[-length(lines)]
    }
    paste(lines, collapse = "\n")
}

captured <- tryCatch(
    paste(capture.output(target(x)), collapse = "\n"),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  error:    ", conditionMessage(e)))
)

if (!identical(.ck_normalize(captured), .ck_normalize(expected_output))) {
    failed(paste0(
        "wrong output\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", chickadee_format(.ck_normalize(expected_output)), "\n",
        "  got:      ", chickadee_format(.ck_normalize(captured))))
}

passed("Printed the expected output")