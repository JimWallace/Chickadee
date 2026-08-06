# Test: b
# Generated from pattern family "Family" [fam] spec_hash=567149c178ff72bc — edit the family, not this file.
source("test_runtime.R")

x <- 18.49

expected <- 1

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