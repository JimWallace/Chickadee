# test_runtime.R — Chickadee R test helper library.
# Source at the top of each R test script: source("test_runtime.R")
#
# API:
#   passed(message = NULL)     — exit 0  (pass)
#   failed(message = "failed") — exit 1  (fail)
#   errored(message = "error") — exit 2  (error)
#
# No external package dependencies; JSON is hand-formatted so this works
# on bare R installs without jsonlite.
#
# This file is the canonical source for the runtime that the runner injects
# into every test working directory. Keep it in sync with the `testRuntimeR`
# string literal in Sources/Worker/RunnerDaemon.swift.

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
