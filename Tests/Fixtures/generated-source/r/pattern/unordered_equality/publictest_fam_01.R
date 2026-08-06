# Test: u
# Generated from pattern family "Family" [fam] spec_hash=742f48b545094cfb — edit the family, not this file.
source("test_runtime.R")

x <- 1

expected <- c(1, 2)

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

result <- tryCatch(
    target(x),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: the same elements as ", chickadee_format(expected), "\n",
        "  error:    ", conditionMessage(e)))
)

if (!chickadee_unordered_equal(result, expected)) {
    failed(paste0(
        "wrong elements\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: the same elements as ", chickadee_format(expected), "\n",
        "  got:      ", chickadee_format(result)))
}

passed(paste0("Returned ", chickadee_format(result)))