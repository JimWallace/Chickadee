# test_runtime.R — Chickadee R test helper library.
# Source at the top of each R test script: source("test_runtime.R")
#
# API:
#   passed(message = NULL)     — exit 0  (pass)
#   failed(message = "failed") — exit 1  (fail)
#   errored(message = "error") — exit 2  (error)
#   chickadee_seed()           — deterministic per-student integer seed
#   chickadee_inputs()         — per-student inputs from _ck_inputs.R
#
# No external package dependencies; JSON is hand-formatted so this works
# on bare R installs without jsonlite.
#
# This file is the canonical source for the runtime that the runner injects
# into every test working directory. The helper API is inlined as the
# `testRuntimeRHelpers` string literal in Sources/Worker/TestRuntimeSources.swift;
# the chickadee_seed()/chickadee_inputs() blocks below mirror
# Sources/Core/RPersonalizationRuntime.swift (composed onto the helpers there so
# the server-side expression driver and this grading runtime compute the seed
# identically). Keep all three in sync when editing.

.chickadee_json_str <- function(x) {
    x <- as.character(x)
    x <- gsub("\\\\", "\\\\\\\\", x, fixed = TRUE)
    x <- gsub('"',    '\\\\"',    x, fixed = TRUE)
    x <- gsub("\n",   "\\\\n",    x, fixed = TRUE)
    x <- gsub("\r",   "\\\\r",    x, fixed = TRUE)
    x <- gsub("\t",   "\\\\t",    x, fixed = TRUE)
    paste0('"', x, '"')
}

.chickadee_label <- function() {
    args  <- commandArgs(trailingOnly = FALSE)
    fargs <- args[startsWith(args, "--file=")]
    if (length(fargs) > 0L) {
        path <- sub("^--file=", "", fargs[[1L]])
        return(tools::file_path_sans_ext(basename(path)))
    }
    "test"
}

.chickadee_emit <- function(status, short_result, error = NULL) {
    label <- .chickadee_label()
    parts <- c(
        paste0('"status":',      .chickadee_json_str(status)),
        paste0('"shortResult":', .chickadee_json_str(short_result)),
        paste0('"test":',        .chickadee_json_str(label))
    )
    if (!is.null(error)) {
        parts <- c(parts, paste0('"error":', .chickadee_json_str(as.character(error))))
    }
    cat(paste0("{", paste(parts, collapse = ","), "}\n"))
}

passed <- function(message = NULL) {
    label <- .chickadee_label()
    msg   <- if (!is.null(message)) as.character(message) else paste0(label, ": passed")
    .chickadee_emit("pass", msg)
    quit(status = 0L, save = "no")
}

failed <- function(message = "failed") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("fail", paste0(label, ": ", msg), error = msg)
    quit(status = 1L, save = "no")
}

errored <- function(message = "error") {
    label <- .chickadee_label()
    msg   <- as.character(message)
    .chickadee_emit("error", paste0(label, ": ", msg), error = msg)
    quit(status = 2L, save = "no")
}

# --- Per-student personalization primitives ---------------------------------
# Mirror of Sources/Core/RPersonalizationRuntime.swift. base R has no bignum, so
# the 256-bit hex seed is folded with Horner's method modulo 2^31-1 (every
# intermediate stays < 2^35, safely inside a double). Deterministic per student
# and identical wherever called, so R stays self-consistent.

chickadee_seed <- function() {
    hex <- tolower(gsub("[^0-9a-fA-F]", "", Sys.getenv("CHICKADEE_ASSIGNMENT_SEED", "")))
    if (!nzchar(hex)) return(0L)
    digits <- strtoi(strsplit(hex, "")[[1L]], 16L)
    modulus <- 2147483647            # 2^31 - 1; intermediates stay < 2^35
    acc <- 0
    for (d in digits) acc <- (acc * 16 + d) %% modulus
    as.integer(acc)
}

# Returns the per-student grading inputs the worker materialized into
# _ck_inputs.R (a `.ck_inputs <- list(...)` binding), or an empty list when none
# were delivered. The R mirror of a Python test reading _ck["name"].
chickadee_inputs <- function() {
    if (!file.exists("_ck_inputs.R")) return(list())
    env <- new.env(parent = baseenv())
    ok <- tryCatch({ sys.source("_ck_inputs.R", envir = env); TRUE },
                   error = function(e) FALSE)
    if (ok && exists(".ck_inputs", envir = env, inherits = FALSE)) {
        get(".ck_inputs", envir = env)
    } else {
        list()
    }
}

# --- Locating the student's submission --------------------------------------
# Mirror of the testRuntimeRStudentFile block in
# Sources/Worker/TestRuntimeSources.swift (where the reserved inputs filename is
# interpolated from AssignmentLanguage). Filenames Chickadee itself writes into
# the grading workspace are never the student's submission.
.chickadee_reserved_files <- c("test_runtime.R", "_ck_inputs.R")

.chickadee_is_test_file <- function(names) {
    grepl("^(publictest|releasetest|secrettest|studenttest)", names)
}

# The test script currently executing. It is itself a .R file sitting in the
# working directory, so it must never be mistaken for the submission - the
# tier-prefix rule above only covers the conventional names.
.chickadee_running_script <- function() {
    args  <- commandArgs(trailingOnly = FALSE)
    fargs <- args[startsWith(args, "--file=")]
    if (length(fargs) > 0L) return(basename(sub("^--file=", "", fargs[[1L]])))
    ""
}

# The student's submitted R file: solution.R during validation, the extracted
# notebook during grading. Prefers the runner's `.chickadee_student_module`
# hint when it names an R file that is actually present, then falls back to
# scanning the working directory. `extra_skip` lets an assignment exclude its
# own bundled helpers, e.g. chickadee_student_file(c("a2_helpers.R")).
# Returns NA_character_ when nothing looks like a submission.
chickadee_student_file <- function(extra_skip = character(0)) {
    hint_path <- ".chickadee_student_module"
    if (file.exists(hint_path)) {
        hinted <- tryCatch(trimws(readLines(hint_path, warn = FALSE)),
                           error = function(e) character(0))
        hinted <- hinted[nzchar(hinted)]
        if (length(hinted) > 0L) {
            preferred <- basename(hinted[[1L]])
            if (grepl("\\.[Rr]$", preferred) && file.exists(preferred)) return(preferred)
        }
    }
    rfiles <- list.files(pattern = "\\.[Rr]$")
    skip   <- c(.chickadee_reserved_files, .chickadee_running_script(), extra_skip)
    cand   <- rfiles[!(rfiles %in% skip) & !.chickadee_is_test_file(rfiles)]
    if (length(cand) == 0L) return(NA_character_)
    if ("solution.R" %in% cand) return("solution.R")
    cand[[1L]]
}

# Evaluate the submission expression-by-expression in a fresh environment, so a
# runtime error in one top-level line still leaves the function definitions
# that loaded before it available to the tests.
chickadee_load_student <- function(extra_skip = character(0)) {
    f <- chickadee_student_file(extra_skip)
    if (is.na(f)) errored("No R submission file was found to grade.")

    env <- new.env(parent = globalenv())
    grDevices::pdf(NULL)                 # swallow any plots the notebook draws
    on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)

    exprs <- tryCatch(parse(file = f), error = function(e) NULL)
    if (is.null(exprs)) {
        errored(paste0("Your submission (", f, ") could not be parsed as R - check for a syntax error."))
    }
    for (ex in exprs) tryCatch(eval(ex, envir = env), error = function(e) invisible(NULL))
    env
}

# Fetch a function the student was asked to write; a clear error when it is
# missing or was overwritten with something that is not a function.
chickadee_require_fn <- function(env, name) {
    fn <- tryCatch(get(name, envir = env, inherits = FALSE), error = function(e) NULL)
    if (is.null(fn) || !is.function(fn)) {
        errored(sprintf("Your submission must define a function called `%s()`.", name))
    }
    fn
}
