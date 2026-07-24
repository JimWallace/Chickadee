# Grades summarize(cohort): cohort size, mean age, hypertension rate.
source("test_runtime.R")
source("lab9_helpers.R")

student   <- load_student()
summarize <- require_student_fn(student, "summarize")

ref <- build_cohort(20240617)
got <- tryCatch(
    summarize(ref),
    error = function(e) errored(paste0("summarize() raised an error: ", conditionMessage(e)))
)

if (!is.list(got)) {
    failed(paste0("summarize() should return a named list, but returned a ", class(got)[1], "."))
}
for (key in c("n", "mean_age", "hypertension_rate")) {
    if (is.null(got[[key]])) {
        failed(paste0("summarize() result is missing the `", key, "` element."))
    }
}

nums_ok <- suppressWarnings(
    !is.na(as.numeric(got$n)) &&
    !is.na(as.numeric(got$mean_age)) &&
    !is.na(as.numeric(got$hypertension_rate))
)
if (!nums_ok) {
    failed("summarize() values should be numbers (n is a count; the others are numeric).")
}

exp_n    <- nrow(ref)
exp_age  <- mean(ref$age)
exp_rate <- mean(ref$high_bp)

if (as.integer(got$n) != exp_n) {
    failed(sprintf("`n` is wrong: expected %d, got %s. Hint: nrow(cohort).",
                   exp_n, format(got$n)))
}
if (abs(as.numeric(got$mean_age) - exp_age) > 0.5) {
    failed(sprintf("`mean_age` is off: expected about %.1f, got %s.",
                   exp_age, format(got$mean_age)))
}
if (abs(as.numeric(got$hypertension_rate) - exp_rate) > 0.02) {
    failed(sprintf(paste0("`hypertension_rate` is off: expected about %.3f, got %s. ",
                          "Hint: the mean of a 0/1 column is the fraction of 1s."),
                   exp_rate, format(got$hypertension_rate)))
}

passed(sprintf("summarize is correct (n=%d, mean_age~%.1f, hypertension_rate~%.3f).",
               exp_n, exp_age, exp_rate))
