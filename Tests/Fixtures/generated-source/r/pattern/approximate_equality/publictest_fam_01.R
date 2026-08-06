# Test: b
# Generated from pattern family "Family" [fam] spec_hash=8fff023f74a1087a — edit the family, not this file.
source("test_runtime.R")

x <- 18.49

expected  <- 1
tolerance <- 1e-06

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

result <- tryCatch(
    target(x),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", chickadee_format(expected), " (±", tolerance, ")\n",
        "  error:    ", conditionMessage(e)))
)

if (!is.numeric(result) || length(result) != 1L) {
    failed(paste0(
        "wrong return type\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: a single number close to ", chickadee_format(expected), "\n",
        "  got:      ", chickadee_format(result)))
}

delta <- abs(result - expected)
if (delta > tolerance) {
    failed(paste0(
        "value outside tolerance\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", chickadee_format(expected), " (±", tolerance, ")\n",
        "  got:      ", chickadee_format(result), "\n",
        "  delta:    ", chickadee_format(delta)))
}

passed(paste0("Returned ", chickadee_format(result), " (within ±", tolerance, ")"))