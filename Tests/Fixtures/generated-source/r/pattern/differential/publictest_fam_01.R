# Test: d
# Generated from pattern family "Family" [fam] spec_hash=f57106474c9ddfe3 — edit the family, not this file.
source("test_runtime.R")

x <- 18.49


# Instructor's reference implementation, rendered verbatim.
ck_ref_classify <- function(x) 1

expected <- tryCatch(
    ck_ref_classify(x),
    error = function(e) errored(paste0(
        "the reference implementation raised\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  error:    ", conditionMessage(e)))
)

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

result <- tryCatch(
    target(x),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", chickadee_format(expected), "\n",
        "  error:    ", conditionMessage(e)))
)

if (!chickadee_equal(result, expected)) {
    failed(paste0(
        "wrong value\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", chickadee_format(expected), "\n",
        "  got:      ", chickadee_format(result)))
}

passed(paste0("Returned ", chickadee_format(result)))