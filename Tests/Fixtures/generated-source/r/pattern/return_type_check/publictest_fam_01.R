# Test: t
# Generated from pattern family "Family" [fam] spec_hash=8adb8f0c701a46e7 — edit the family, not this file.
source("test_runtime.R")

x <- 1

expected_type_name <- "int"

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

result <- tryCatch(
    target(x),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: a ", expected_type_name, " return value\n",
        "  error:    ", conditionMessage(e)))
)

if (!(is.numeric(result))) {
    failed(paste0(
        "wrong return type\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  expected: ", expected_type_name, "\n",
        "  got:      ", class(result)[[1L]], " (value: ", chickadee_format(result), ")"))
}

passed(paste0("Returned a ", class(result)[[1L]]))