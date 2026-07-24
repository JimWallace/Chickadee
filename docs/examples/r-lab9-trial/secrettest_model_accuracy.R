# Grades the tuned model: its accuracy on the full dataset must clear the goal.
source("test_runtime.R")
source("lab9_helpers.R")

student         <- load_student()
select_features <- require_student_fn(student, "select_features")

GATE <- 0.70

feats <- tryCatch(
    as.character(select_features()),
    error = function(e) errored(paste0("select_features() raised an error: ", conditionMessage(e)))
)
feats <- intersect(feats, FEATURES)
if (length(feats) == 0L) {
    failed("select_features() returned no usable features.")
}

accuracy <- tryCatch(
    evaluate_model(feats, load_data()),
    error = function(e) errored(paste0("evaluate_model() raised an error: ", conditionMessage(e)))
)

if (accuracy < GATE) {
    failed(sprintf(paste0("Model accuracy %.3f is below the %.2f goal (features: %s).\n",
                          "Hint: include the features that correlate most strongly with high_bp; ",
                          "drop the ones near zero."),
                   accuracy, GATE, paste(feats, collapse = ", ")))
}

passed(sprintf("Model reached %.3f accuracy (>= %.2f) with features %s.",
               accuracy, GATE, paste(feats, collapse = ", ")))
