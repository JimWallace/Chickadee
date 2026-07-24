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
