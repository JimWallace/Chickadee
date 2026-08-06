# Test: p
# Generated from pattern family "Family" [fam] spec_hash=373c736715269bba — edit the family, not this file.
source("test_runtime.R")

x <- 1

budget_ms <- 0.5

student <- chickadee_load_student()
target  <- chickadee_require_fn(student, "classify")

started <- Sys.time()
result <- tryCatch(
    target(x),
    error = function(e) failed(paste0(
        "unexpected exception\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  error:    ", conditionMessage(e)))
)
elapsed_ms <- as.numeric(difftime(Sys.time(), started, units = "secs")) * 1000

if (elapsed_ms > budget_ms) {
    failed(paste0(
        "too slow\n",
        "  input:    ", "x=", chickadee_format(x), "\n",
        "  budget:   ", budget_ms, " ms\n",
        "  took:     ", round(elapsed_ms, 1), " ms\n",
        "  Hint: look for repeated work that could be done once."))
}

passed(paste0("Completed in ", round(elapsed_ms, 1), " ms (budget ", budget_ms, " ms)"))