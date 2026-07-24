# Grades strongest_predictor(cohort): the feature most correlated with high_bp.
source("test_runtime.R")
source("lab9_helpers.R")

student             <- load_student()
strongest_predictor <- require_student_fn(student, "strongest_predictor")

ref  <- build_cohort(20240617)
cors <- vapply(FEATURES, function(f) stats::cor(ref[[f]], ref$high_bp), numeric(1))
expected <- names(which.max(abs(cors)))

got <- tryCatch(
    strongest_predictor(ref),
    error = function(e) errored(paste0("strongest_predictor() raised an error: ", conditionMessage(e)))
)

if (!is.character(got) || length(got) != 1L) {
    failed(paste0("strongest_predictor() should return a single feature name; got ",
                  class(got)[1], " of length ", length(got), "."))
}
if (!identical(got, expected)) {
    failed(sprintf(paste0("strongest_predictor() returned '%s', but the strongest correlate is '%s'.\n",
                          "Hint: take abs() of the correlations, then which.max() to get the biggest."),
                   got, expected))
}

passed(sprintf("strongest_predictor is correct: '%s'.", got))
