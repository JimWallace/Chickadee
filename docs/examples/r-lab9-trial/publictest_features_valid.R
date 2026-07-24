# Grades that select_features() returns a sensible vector of feature names.
source("test_runtime.R")
source("lab9_helpers.R")

student         <- load_student()
select_features <- require_student_fn(student, "select_features")

feats <- tryCatch(
    select_features(),
    error = function(e) errored(paste0("select_features() raised an error: ", conditionMessage(e)))
)

if (!is.character(feats) || length(feats) == 0L) {
    failed(paste0("select_features() must return a non-empty character vector of feature names, got ",
                  class(feats)[1], " of length ", length(feats), "."))
}
unknown <- setdiff(feats, FEATURES)
if (length(unknown) > 0L) {
    failed(paste0("unknown feature name(s): ", paste(unknown, collapse = ", "),
                  ". Choose from: ", paste(FEATURES, collapse = ", "), "."))
}
if (anyDuplicated(feats) > 0L) {
    failed("select_features() has duplicate feature names — list each at most once.")
}

passed(paste0("valid feature selection: ", paste(feats, collapse = ", "), "."))
