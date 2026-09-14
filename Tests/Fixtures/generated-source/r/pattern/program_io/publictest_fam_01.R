# Test: io
# Generated from pattern family "Family" [fam] spec_hash=eb00ef813bc014b0 — edit the family, not this file.
source("test_runtime.R")

stdin_text <- "3\n4\n"
expected   <- "7"

.ck_file <- chickadee_student_file()
if (is.na(.ck_file)) errored("No R submission file was found to run.")

.ck_normalize <- function(text) {
    lines <- strsplit(paste0(as.character(text), "\n"), "\n", fixed = TRUE)[[1L]]
    lines <- sub("[[:space:]]+$", "", lines)
    while (length(lines) > 0L && !nzchar(lines[[length(lines)]])) {
        lines <- lines[-length(lines)]
    }
    paste(lines, collapse = "\n")
}

.ck_lines  <- if (nzchar(stdin_text)) strsplit(stdin_text, "\n", fixed = TRUE)[[1L]] else character(0)
.ck_cursor <- 0L
.ck_take <- function(n = -1L) {
    remaining <- length(.ck_lines) - .ck_cursor
    if (n < 0L || n > remaining) n <- remaining
    if (n <= 0L) return(character(0))
    out <- .ck_lines[(.ck_cursor + 1L):(.ck_cursor + n)]
    .ck_cursor <<- .ck_cursor + n
    out
}
.ck_is_stdin <- function(con) {
    identical(con, "stdin") || identical(con, "") ||
        (inherits(con, "connection") && identical(summary(con)$description, "stdin"))
}
.ck_env <- new.env(parent = globalenv())
.ck_env$readline <- function(prompt = "") {
    cat(prompt)
    v <- .ck_take(1L)
    if (length(v)) v else ""
}
.ck_env$readLines <- function(con = "stdin", n = -1L, ...) {
    if (.ck_is_stdin(con)) return(.ck_take(n))
    base::readLines(con, n, ...)
}
.ck_env$scan <- function(file = "", what = double(), n = -1L, ..., quiet = FALSE) {
    if (.ck_is_stdin(file)) {
        text <- paste(.ck_take(-1L), collapse = "\n")
        return(base::scan(text = text, what = what, n = n, ..., quiet = TRUE))
    }
    base::scan(file = file, what = what, n = n, ..., quiet = quiet)
}
.ck_env$quit <- function(...) stop("chickadee:exit")
.ck_env$q <- .ck_env$quit

.ck_error <- NULL
captured <- paste(capture.output(
    tryCatch(sys.source(.ck_file, envir = .ck_env), error = function(e) {
        if (!identical(conditionMessage(e), "chickadee:exit")) .ck_error <<- conditionMessage(e)
    })), collapse = "\n")

if (!is.null(.ck_error)) {
    failed(paste0(
        "unexpected exception\n",
        "  input:    ", chickadee_format(stdin_text), "\n",
        "  got:      ", chickadee_format(.ck_normalize(captured)), "\n",
        "  error:    ", .ck_error))
}

ok <- identical(.ck_normalize(captured), .ck_normalize(expected))
if (!isTRUE(ok)) {
    failed(paste0(
        "wrong output\n",
        "  input:    ", chickadee_format(stdin_text), "\n",
        "  expected: ", chickadee_format(expected), "\n",
        "  got:      ", chickadee_format(.ck_normalize(captured))))
}

passed("Printed the expected output")