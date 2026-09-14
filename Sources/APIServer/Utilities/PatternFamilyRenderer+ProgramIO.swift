// APIServer/Utilities/PatternFamilyRenderer+ProgramIO.swift
//
// `.programIO` renderer: run the submission as a whole program with the
// case's stdin text and compare what it printed. Every language's rendering
// lives in this file, per the kind-per-file rule stated in
// PatternFamilyRenderer+StdoutEquality.swift.
//
// WHAT IS SHARED. The stdin text and the expected text are the case's two
// strings. Output is normalised the same way everywhere — trailing whitespace
// on each line and trailing blank lines dropped — and compared under the
// family's `ioComparison`: exact (normalised equality), included (substring),
// or regex (search). A crash is a graded failure headed "unexpected
// exception" with the student's own output and the error; a mismatch is
// "wrong output" with the input, the expectation and the output.
//
// WHAT IS PER LANGUAGE is how a program is RUN with fed input, and it is
// deliberately in-process on every kernel language so the kind grades in the
// browser: a xeus kernel has no subprocess. Python swaps `sys.stdin` and
// `builtins.input` around `runpy`; R masks `readline` / `readLines("stdin")` /
// `scan()` in the environment the file is sourced into; Lua proxies `io.read`
// / `io.lines` / `io.stdin` beside the `print` capture the stdout kind already
// uses; Octave shadows `input()` with a command-line function; Racket
// parameterizes `current-input-port`. C++ and Java are native-only and compile
// the submission to a real program run with the text on its real stdin.
//
// Every in-process runner also masks the program's exit call (`exit()` /
// `quit()` / `os.exit` / `(exit)`): a program that exits after printing its
// answer is normal, and without the mask that exit would end the TEST with
// status 0 — the `quit()` hazard the runtimes' headers describe.

import Core
import Foundation

// MARK: - Shared

/// The `expected:` line's value prefix, naming the comparison when it is not
/// plain equality so a student reads "output containing '7'" rather than
/// an equality they never failed.
private func programIOExpectedPrefix(_ comparison: ProgramIOComparison) -> String {
    switch comparison {
    case .exact: return ""
    case .included: return "output containing "
    case .regex: return "output matching "
    }
}

/// The stdin text a case feeds, or "" — `validateCase` has already required a
/// single string arg, so anything else renders as empty input rather than
/// failing to render.
private func programIOStdin(_ c: PatternCase) -> String {
    if case .string(let text)? = c.args.first { return text }
    return ""
}

private func programIOExpected(_ c: PatternCase) -> String {
    if case .string(let text) = c.expected { return text }
    return ""
}

// MARK: - Python

/// Feeds `sys.stdin` AND `builtins.input`: the second because a kernel replaces
/// `input` with its own request-based implementation, which a swapped
/// `sys.stdin` would not reach. The prompt is echoed as a terminal would, so an
/// author who expects "Enter a number: 7" on one line gets it.
func renderProgramIO(
    family: PatternFamily,
    case c: PatternCase,
    sectionVariables: [FamilyVariable],
    specHash: String
) -> String {
    let comparison = family.resolvedIOComparison
    let variableDecls = combinedVariableDecls(
        sectionVariables: sectionVariables, family: family, language: .python)
    let variableBlock = variableDecls.isEmpty ? "" : variableDecls + "\n\n"
    let compare: String
    switch comparison {
    case .exact: compare = "_ok = actual == _normalize(expected)"
    case .included: compare = "_ok = expected in actual"
    case .regex: compare = "_ok = _re.search(expected, actual, _re.MULTILINE) is not None"
    }
    return """
        \(generatedCaseHeader(family: family, case: c, specHash: specHash))

        import builtins as _builtins
        import contextlib as _contextlib
        import io as _io
        import re as _re
        import runpy as _runpy
        import sys as _sys
        import test_runtime as _tr

        \(variableBlock)stdin_text = \(JSONValue.string(programIOStdin(c)).pythonLiteral)
        expected = \(JSONValue.string(programIOExpected(c)).pythonLiteral)

        _files = _tr._ordered_student_files()
        if not _files:
            errored("No Python submission file was found to run.")


        def _normalize(text):
            lines = [line.rstrip() for line in str(text).replace("\\r\\n", "\\n").split("\\n")]
            while lines and not lines[-1]:
                lines.pop()
            return "\\n".join(lines)


        _stdin = _io.StringIO(stdin_text)
        _out = _io.StringIO()
        _saved_stdin, _saved_input = _sys.stdin, _builtins.input


        def _fed_input(prompt=""):
            _sys.stdout.write(str(prompt))
            line = _stdin.readline()
            if not line:
                raise EOFError("EOF when reading a line")
            return line.rstrip("\\n")


        _error = None
        try:
            _sys.stdin = _stdin
            _builtins.input = _fed_input
            with _contextlib.redirect_stdout(_out):
                try:
                    _runpy.run_path(str(_files[0]), run_name="__main__")
                except SystemExit:
                    pass
                except BaseException as ex:
                    _error = f"{type(ex).__name__}: {ex}"
        finally:
            _sys.stdin = _saved_stdin
            _builtins.input = _saved_input

        actual = _normalize(_out.getvalue())
        if _error is not None:
            failed(
                "\(GeneratedMessage.unexpectedException)\\n"
                f"\(GeneratedMessage.input){stdin_text!r}\\n"
                f"\(GeneratedMessage.got){actual!r}\\n"
                f"\(GeneratedMessage.error){_error}\\n"
            )

        \(compare)
        if not _ok:
            failed(
                "\(GeneratedMessage.wrongOutput)\\n"
                f"\(GeneratedMessage.input){stdin_text!r}\\n"
                f"\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison)){expected!r}\\n"
                f"\(GeneratedMessage.got){actual!r}\\n"
            )

        passed("Printed the expected output")
        """
}

// MARK: - R

/// Sources the file into an environment whose `readline`, `readLines` (for
/// `"stdin"` / `stdin()`) and `scan` (for `file = ""` / `"stdin"`) draw from
/// the case's lines. `file("stdin")` is not masked: it opens the process's
/// real stream and cannot be redirected from inside R.
func rProgramIOCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let comparison = family.resolvedIOComparison
    let compare: String
    switch comparison {
    case .exact: compare = "ok <- identical(.ck_normalize(captured), .ck_normalize(expected))"
    case .included: compare = "ok <- grepl(expected, captured, fixed = TRUE)"
    case .regex: compare = "ok <- grepl(paste0(\"(?m)\", expected), .ck_normalize(captured), perl = TRUE)"
    }
    return """
        \(prelude)

        stdin_text <- \(JSONValue.string(programIOStdin(c)).rLiteral)
        expected   <- \(JSONValue.string(programIOExpected(c)).rLiteral)

        .ck_file <- chickadee_student_file()
        if (is.na(.ck_file)) errored("No R submission file was found to run.")

        .ck_normalize <- function(text) {
            lines <- strsplit(paste0(as.character(text), "\\n"), "\\n", fixed = TRUE)[[1L]]
            lines <- sub("[[:space:]]+$", "", lines)
            while (length(lines) > 0L && !nzchar(lines[[length(lines)]])) {
                lines <- lines[-length(lines)]
            }
            paste(lines, collapse = "\\n")
        }

        .ck_lines  <- if (nzchar(stdin_text)) strsplit(stdin_text, "\\n", fixed = TRUE)[[1L]] else character(0)
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
                text <- paste(.ck_take(-1L), collapse = "\\n")
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
            })), collapse = "\\n")

        if (!is.null(.ck_error)) {
            failed(paste0(
                "\(GeneratedMessage.unexpectedException)\\n",
                "\(GeneratedMessage.input)", chickadee_format(stdin_text), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(.ck_normalize(captured)), "\\n",
                "\(GeneratedMessage.error)", .ck_error))
        }

        \(compare)
        if (!isTRUE(ok)) {
            failed(paste0(
                "\(GeneratedMessage.wrongOutput)\\n",
                "\(GeneratedMessage.input)", chickadee_format(stdin_text), "\\n",
                "\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison))", chickadee_format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee_format(.ck_normalize(captured))))
        }

        passed("Printed the expected output")
        """
}

// MARK: - Lua

/// The Lua stdin reader (`io.read` forms `l`/`L`/`n`/`a`/count, with or
/// without the legacy `*`) and the two stream proxies the submission's `io`
/// is built from. Hoisted so the case renderer stays within the body-length
/// limit; it is one string, interpolated verbatim.
private let luaProgramIOStreamProxies = """
    local ck_pos = 1
    local function ck_read_line(keep_newline)
        if ck_pos > #stdin_text then return nil end
        local nl = stdin_text:find("\\n", ck_pos, true)
        local line
        if nl then
            line = stdin_text:sub(ck_pos, keep_newline and nl or nl - 1)
            ck_pos = nl + 1
        else
            line = stdin_text:sub(ck_pos)
            ck_pos = #stdin_text + 1
        end
        return line
    end
    local function ck_read_one(fmt)
        if fmt == nil then return ck_read_line(false) end
        if type(fmt) == "number" then
            if ck_pos > #stdin_text then return nil end
            local s = stdin_text:sub(ck_pos, ck_pos + fmt - 1)
            ck_pos = ck_pos + fmt
            return s
        end
        fmt = tostring(fmt):gsub("^%*", "")
        if fmt == "n" then
            local rest = stdin_text:sub(ck_pos)
            local _, e, num = rest:find("^%s*([%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*)")
            if not num then return nil end
            ck_pos = ck_pos + e
            return tonumber(num)
        elseif fmt == "a" then
            local s = stdin_text:sub(ck_pos)
            ck_pos = #stdin_text + 1
            return s
        elseif fmt == "L" then
            return ck_read_line(true)
        end
        return ck_read_line(false)
    end

    local captured = {}
    local ck_stdout = {}
    function ck_stdout.write(...)
        local n = select("#", ...)
        local start = (n >= 1 and select(1, ...) == ck_stdout) and 2 or 1
        for i = start, n do
            captured[#captured + 1] = tostring((select(i, ...)))
        end
        return ck_stdout
    end
    local ck_stdin = {}
    function ck_stdin.read(...)
        local n = select("#", ...)
        local start = (n >= 1 and select(1, ...) == ck_stdin) and 2 or 1
        if n < start then return ck_read_one(nil) end
        local results = {}
        for i = start, n do
            results[#results + 1] = ck_read_one((select(i, ...)))
        end
        return table.unpack(results, 1, n - start + 1)
    end
    function ck_stdin.lines(...)
        return function() return ck_read_line(false) end
    end
    """

/// Loads the file into a fresh environment whose `io` proxies both directions:
/// the stdout capture the stdout kind uses, plus `read`, `lines` and `stdin`
/// drawing from the case text. `io.read` honours `"l"`, `"L"`, `"n"`, `"a"`
/// and a byte count, with or without the legacy `*`. `os.exit` raises so a
/// program that exits after its answer still gets graded.
func luaProgramIOCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let comparison = family.resolvedIOComparison
    let compare: String
    switch comparison {
    case .exact: compare = "local ok = ck_normalize(actual_output) == ck_normalize(expected)"
    case .included: compare = "local ok = string.find(actual_output, expected, 1, true) ~= nil"
    // Refused at save time; rendered as `included` so a stale spec still
    // grades something rather than erroring on every student.
    case .regex: compare = "local ok = string.find(actual_output, expected, 1, true) ~= nil"
    }
    return """
        \(prelude)

        local stdin_text = \(JSONValue.string(programIOStdin(c)).luaLiteral)
        local expected = \(JSONValue.string(programIOExpected(c)).luaLiteral)

        local file = chickadee.student_file()
        if not file then
            chickadee.errored("No Lua submission file was found to run.")
        end

        local function ck_normalize(text)
            local lines = {}
            for line in (tostring(text) .. "\\n"):gmatch("([^\\n]*)\\n") do
                lines[#lines + 1] = (line:gsub("%s+$", ""))
            end
            while #lines > 0 and lines[#lines] == "" do
                table.remove(lines)
            end
            return table.concat(lines, "\\n")
        end

        \(luaProgramIOStreamProxies)

        local env = setmetatable({}, { __index = _G })
        env.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            captured[#captured + 1] = table.concat(parts, "\\t") .. "\\n"
        end
        env.io = setmetatable({
            write = ck_stdout.write,
            read = ck_stdin.read,
            lines = function(name, ...)
                if name == nil then return ck_stdin.lines() end
                return io.lines(name, ...)
            end,
            stdout = ck_stdout,
            stdin = ck_stdin,
        }, { __index = io })
        env.os = setmetatable({ exit = function() error("chickadee:exit", 0) end }, { __index = os })

        local chunk, load_err = loadfile(file, "t", env)
        if not chunk then
            chickadee.failed("Your submission (" .. file .. ") could not be parsed as Lua: " .. tostring(load_err))
        end
        local ran, run_err = pcall(chunk)
        local actual_output = table.concat(captured)

        if not ran and tostring(run_err) ~= "chickadee:exit" then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.unexpectedException)\\n",
                "\(GeneratedMessage.input)", chickadee.format(stdin_text), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(ck_normalize(actual_output)), "\\n",
                "\(GeneratedMessage.error)", tostring(run_err),
            }))
        end

        \(compare)
        if not ok then
            chickadee.failed(table.concat({
                "\(GeneratedMessage.wrongOutput)\\n",
                "\(GeneratedMessage.input)", chickadee.format(stdin_text), "\\n",
                "\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison))", chickadee.format(expected), "\\n",
                "\(GeneratedMessage.got)", chickadee.format(ck_normalize(actual_output)),
            }))
        end

        chickadee.passed("Printed the expected output")
        """
}

// MARK: - Octave

/// The command-line functions that shadow `input`, `exit` and `quit` while
/// the program runs. `input` draws from the global line cursor the case sets
/// up; the exit masks raise `chickadee:exit` only while `ck_program_running`
/// is set, and otherwise forward to the exit that was visible before them.
private let octaveProgramIOMasks = """
    function r = input(prompt, varargin)
        global ck_stdin_lines ck_stdin_pos
        printf("%s", prompt);
        if ck_stdin_pos > numel(ck_stdin_lines)
            error("chickadee:eof", "end of input");
        end
        line = ck_stdin_lines{ck_stdin_pos};
        ck_stdin_pos = ck_stdin_pos + 1;
        if nargin > 1
            r = line;
        else
            r = str2num(line);
            if isempty(r)
                r = line;
            end
        end
    end
    function exit(varargin)
        global ck_program_running ck_prev_exit
        if ck_program_running
            error("chickadee:exit", "exit");
        end
        ck_prev_exit(varargin{:});
    end
    function quit(varargin)
        global ck_program_running ck_prev_quit
        if ck_program_running
            error("chickadee:exit", "exit");
        end
        ck_prev_quit(varargin{:});
    end
    """

/// Shadows `input` (and `exit` / `quit`) with command-line functions for the
/// duration of the program run. Command-line functions shadow builtins, and
/// the masks read the previously visible `exit` through a handle captured
/// first, so the runtime's own verdict exits — the builtin natively, the
/// browser wrapper's mask in the kernel — still reach the right place.
func octaveProgramIOCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let comparison = family.resolvedIOComparison
    let compare: String
    switch comparison {
    case .exact: compare = "ok = strcmp(ck_normalize(captured), ck_normalize(expected));"
    case .included: compare = "ok = !isempty(strfind(captured, expected));"
    case .regex: compare = "ok = !isempty(regexp(ck_normalize(captured), expected, \"once\", \"lineanchors\"));"
    }
    return """
        \(prelude)

        stdin_text = \(JSONValue.string(programIOStdin(c)).octaveLiteral);
        expected = \(JSONValue.string(programIOExpected(c)).octaveLiteral);

        ck_file = chickadee.student_file();
        if isempty(ck_file)
            chickadee.errored("No Octave submission file was found to run.");
        end

        function out = ck_normalize(text)
            lines = strsplit(text, sprintf("\\n"), "CollapseDelimiters", false);
            for i = 1:numel(lines)
                lines{i} = regexprep(lines{i}, '\\s+$', "");
            end
            while !isempty(lines) && isempty(lines{end})
                lines(end) = [];
            end
            out = strjoin(lines, sprintf("\\n"));
        end

        global ck_stdin_lines ck_stdin_pos ck_program_running ck_prev_exit ck_prev_quit
        ck_stdin_lines = strsplit(stdin_text, sprintf("\\n"), "CollapseDelimiters", false);
        if !isempty(ck_stdin_lines) && isempty(ck_stdin_lines{end})
            ck_stdin_lines(end) = [];
        end
        ck_stdin_pos = 1;
        ck_program_running = false;
        ck_prev_exit = @exit;
        ck_prev_quit = @quit;

        \(octaveProgramIOMasks)

        ck_text = fileread(ck_file);
        ck_error = "";
        ck_program_running = true;
        try
            captured = evalc("eval([\\"1;\\" sprintf(\\"\\\\n\\") ck_text]);");
        catch err
            captured = "";
            if !strcmp(err.identifier, "chickadee:exit")
                ck_error = err.message;
            end
        end
        ck_program_running = false;

        if !isempty(ck_error)
            chickadee.failed(["\(GeneratedMessage.unexpectedException)\\n" ...
                "\(GeneratedMessage.input)" chickadee.format(stdin_text) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(ck_normalize(captured)) "\\n" ...
                "\(GeneratedMessage.error)" ck_error]);
        end

        \(compare)
        if !ok
            chickadee.failed(["\(GeneratedMessage.wrongOutput)\\n" ...
                "\(GeneratedMessage.input)" chickadee.format(stdin_text) "\\n" ...
                "\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison))" chickadee.format(expected) "\\n" ...
                "\(GeneratedMessage.got)" chickadee.format(ck_normalize(captured))]);
        end

        chickadee.passed("Printed the expected output");
        """
}

// MARK: - Racket

/// Instantiates the module in a fresh namespace under a parameterized
/// `current-input-port`, so a `#lang racket` program's `read-line` reads the
/// case text and a BSL module's top-level values print into the capture.
func racketProgramIOCase(family: PatternFamily, case c: PatternCase, prelude: String) -> String {
    let comparison = family.resolvedIOComparison
    let compare: String
    switch comparison {
    case .exact: compare = "(define ok (string=? (ck-normalize printed) (ck-normalize expected)))"
    case .included: compare = "(define ok (string-contains? printed expected))"
    case .regex:
        compare = "(define ok (regexp-match? (pregexp (string-append \"(?m:\" expected \")\")) (ck-normalize printed)))"
    }
    return """
        \(prelude)
        (require racket/string)

        (define stdin-text \(JSONValue.string(programIOStdin(c)).racketLiteral))
        (define expected \(JSONValue.string(programIOExpected(c)).racketLiteral))

        (define file (chickadee-student-file))
        (unless file (chickadee-errored "No Racket submission file was found to run."))

        (define (ck-normalize text)
          (define lines (map string-trim-right (string-split text "\\n" #:trim? #f)))
          (let loop ([ls (reverse lines)])
            (if (and (pair? ls) (string=? (car ls) ""))
                (loop (cdr ls))
                (string-join (reverse ls) "\\n"))))
        (define (string-trim-right s) (string-trim s #:left? #f))

        (define ck-error #f)
        (define printed
          (let ([out (open-output-string)])
            (parameterize ([current-input-port (open-input-string stdin-text)]
                           [current-output-port out]
                           [current-namespace (make-base-namespace)]
                           [exit-handler (lambda (code) (raise 'chickadee-exit))])
              (with-handlers ([(lambda (e) (eq? e 'chickadee-exit)) void]
                              [exn:fail? (lambda (e) (set! ck-error (exn-message e)))])
                (dynamic-require `(file ,(path->string (path->complete-path file))) #f)))
            (get-output-string out)))

        (when ck-error
          (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.unexpectedException).racketLiteral) "\\n"
                             \(JSONValue.string(GeneratedMessage.input).racketLiteral) (chickadee-format stdin-text) "\\n"
                             \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format (ck-normalize printed)) "\\n"
                             \(JSONValue.string(GeneratedMessage.error).racketLiteral) ck-error)))

        \(compare)
        (if ok
            (chickadee-passed "Printed the expected output")
            (chickadee-failed (string-append \(JSONValue.string(GeneratedMessage.wrongOutput).racketLiteral) "\\n"
                               \(JSONValue.string(GeneratedMessage.input).racketLiteral) (chickadee-format stdin-text) "\\n"
                               \(JSONValue.string(GeneratedMessage.expected + programIOExpectedPrefix(comparison)).racketLiteral) (chickadee-format expected) "\\n"
                               \(JSONValue.string(GeneratedMessage.got).racketLiteral) (chickadee-format (ck-normalize printed)))))
        """ + "\n"
}

// MARK: - C++

/// The checker translation unit: spawns the compiled program with the stdin
/// file on its input, reads back both streams, and grades under the family's
/// comparison. Split from the wrapper for the body-length limit.
/// The scratch filenames one C++ case's wrapper and checker share.
private struct CppProgramIOFiles {
    let programBinary: String
    let stdinFile: String
    let outFile: String
    let errFile: String
}

private func cppProgramIOChecker(
    family: PatternFamily, case c: PatternCase, specHash: String, comparison: ProgramIOComparison,
    files: CppProgramIOFiles
) -> String {
    let compare: String
    switch comparison {
    case .exact: compare = "bool ck_ok = ck_normalize(ck_printed) == ck_normalize(expected);"
    case .included: compare = "bool ck_ok = ck_printed.find(expected) != std::string::npos;"
    case .regex: compare = "bool ck_ok = ck_regex_any_line(ck_normalize(ck_printed), expected);"
    }
    return """
        \(cppComment("Generated by Chickadee — pattern family '\(family.id)', case '\(c.key)'."))
        \(cppComment("Edit the family, not this file. spec_hash: \(specHash)"))
        #include "test_runtime.hpp"
        #include <regex>
        #include <sys/wait.h>

        static std::string ck_read_file(const char* path) {
            std::ifstream in(path, std::ios::binary);
            std::ostringstream ss;
            ss << in.rdbuf();
            return ss.str();
        }
        static bool ck_regex_any_line(const std::string& text, const std::string& pattern) {
            std::regex re(pattern, std::regex::ECMAScript);
            if (std::regex_search(text, re)) return true;
            std::istringstream in(text);
            for (std::string line; std::getline(in, line);) {
                if (std::regex_search(line, re)) return true;
            }
            return false;
        }
        static std::string ck_normalize(const std::string& text) {
            std::vector<std::string> lines;
            std::string current;
            for (char ch : text) {
                if (ch == '\\n') { lines.push_back(current); current.clear(); }
                else if (ch != '\\r') { current.push_back(ch); }
            }
            lines.push_back(current);
            for (auto& line : lines) {
                while (!line.empty() && std::isspace(static_cast<unsigned char>(line.back()))) line.pop_back();
            }
            while (!lines.empty() && lines.back().empty()) lines.pop_back();
            std::string out;
            for (std::size_t i = 0; i < lines.size(); ++i) {
                if (i) out.push_back('\\n');
                out += lines[i];
            }
            return out;
        }

        int main() {
            std::string stdin_text = \(JSONValue.string(programIOStdin(c)).cppLiteral);
            std::string expected = \(JSONValue.string(programIOExpected(c)).cppLiteral);
            int ck_status = std::system("./\(files.programBinary) < \(files.stdinFile) > \(files.outFile) 2> \(files.errFile)");
            std::string ck_printed = ck_read_file("\(files.outFile)");
            std::string ck_stderr = ck_read_file("\(files.errFile)");
            int ck_code = WIFEXITED(ck_status) ? WEXITSTATUS(ck_status) : -1;
            if (ck_code != 0) {
                ck::failed(std::string("\(GeneratedMessage.unexpectedException)\\n")
                    + "\(GeneratedMessage.input)" + ck::format(stdin_text) + "\\n"
                    + "\(GeneratedMessage.got)" + ck::format(ck_normalize(ck_printed)) + "\\n"
                    + "\(GeneratedMessage.error)the program exited with status " + std::to_string(ck_code)
                    + (ck_stderr.empty() ? std::string("") : ": " + ck_normalize(ck_stderr)));
            }
            \(compare)
            if (!ck_ok) {
                ck::failed(std::string("\(GeneratedMessage.wrongOutput)\\n")
                    + "\(GeneratedMessage.input)" + ck::format(stdin_text) + "\\n"
                    + "\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison))" + ck::format(expected) + "\\n"
                    + "\(GeneratedMessage.got)" + ck::format(ck_normalize(ck_printed)));
            }
            ck::passed("Printed the expected output");
        }
        """
}

/// A shell wrapper that compiles the submission to its own binary (the
/// student's `main` is the program), writes the stdin text to a file, then
/// compiles and runs a checker translation unit that spawns the binary with
/// that file on its stdin and grades what came back. Two compiles, because
/// the program and the checker cannot share a `main`.
func cppProgramIOCase(family: PatternFamily, case c: PatternCase, specHash: String) -> String {
    let comparison = family.resolvedIOComparison
    let stem = "\(family.id)_\(c.key)"
    let programBinary = ".ck_prog_\(stem)"
    let stdinFile = ".ck_stdin_\(stem)"
    let outFile = ".ck_out_\(stem)"
    let errFile = ".ck_err_\(stem)"
    let checkerSource = ".ck_src_\(stem).cpp"
    let checkerBinary = ".ck_bin_\(stem)"
    let checker = cppProgramIOChecker(
        family: family, case: c, specHash: specHash, comparison: comparison,
        files: CppProgramIOFiles(
            programBinary: programBinary, stdinFile: stdinFile, outFile: outFile, errFile: errFile))
    return """
        #!/bin/sh
        # Generated by Chickadee — do not edit. This wrapper compiles the
        # submission as a whole program, runs it with the case's standard
        # input, and grades what it printed under the ordinary shell-script
        # contract.
        student_file=""
        if [ -f .chickadee_student_module ]; then
            student_file=$(cat .chickadee_student_module)
        fi
        if [ ! -f "$student_file" ]; then
            for candidate in *.cpp; do
                case "$candidate" in
                    *test_*) ;;
                    *) student_file="$candidate"; break ;;
                esac
            done
        fi
        if [ ! -f "$student_file" ]; then
            echo "No C++ submission file was found to run." 1>&2
            exit 2
        fi
        if ! g++ -std=c++20 -O0 "$student_file" -o \(shellSingleQuoted(programBinary)) >.ck_build_log 2>&1; then
            cat .ck_build_log 1>&2
            printf '%s\\n' \(shellSingleQuoted("{\"shortResult\": \"the submission does not compile\"}"))
            exit 1
        fi
        printf '%s' \(shellSingleQuoted(programIOStdin(c))) > \(shellSingleQuoted(stdinFile))
        cat > \(shellSingleQuoted(checkerSource)) <<'\(generatedSourceHeredocDelimiter)'
        \(checker)
        \(generatedSourceHeredocDelimiter)
        if ! g++ -std=c++20 -O0 \(shellSingleQuoted(checkerSource)) -o \(shellSingleQuoted(checkerBinary)) >.ck_build_log 2>&1; then
            cat .ck_build_log 1>&2
            exit 2
        fi
        ck_out=$(\(shellSingleQuoted("./" + checkerBinary)))
        ck_rc=$?
        if ! printf '%s\\n' "$ck_out" | grep -q '^CK_SENTINEL$'; then
            echo "The test did not run to completion." 1>&2
            exit 2
        fi
        printf '%s\\n' "$ck_out" | grep -v '^CK_SENTINEL$'
        exit $ck_rc
        """ + "\n"
}

// MARK: - Java

/// A shell wrapper around a checker class that runs the submission in
/// source-file mode (`java Student.java`) with the case text on its stdin.
/// Source-file mode compiles the one file each run, which is what lets the
/// submission carry its own `main` without the checker having to know its
/// class name.
func javaProgramIOCase(family: PatternFamily, case c: PatternCase, specHash: String) -> String {
    let comparison = family.resolvedIOComparison
    let stem = "\(family.id)_\(c.key)"
    let className = "CkProgram_" + javaGeneratedClassName(forStem: stem)
    let stdinFile = ".ck_stdin_\(stem)"
    let compare: String
    switch comparison {
    case .exact: compare = "boolean ckOk = ckNormalize(ckPrinted).equals(ckNormalize(expected));"
    case .included: compare = "boolean ckOk = ckPrinted.contains(expected);"
    case .regex:
        compare =
            "boolean ckOk = java.util.regex.Pattern.compile(expected, java.util.regex.Pattern.MULTILINE).matcher(ckNormalize(ckPrinted)).find();"
    }
    let checker = """
        \(javaComment("Generated by Chickadee — pattern family '\(family.id)', case '\(c.key)'."))
        \(javaComment("Edit the family, not this file. spec_hash: \(specHash)"))
        public class \(className) {
            static String ckNormalize(String text) {
                String[] lines = text.replace("\\r\\n", "\\n").split("\\n", -1);
                java.util.List<String> kept = new java.util.ArrayList<>();
                for (String line : lines) kept.add(line.replaceAll("\\\\s+$", ""));
                while (!kept.isEmpty() && kept.get(kept.size() - 1).isEmpty()) kept.remove(kept.size() - 1);
                return String.join("\\n", kept);
            }
            public static void main(String[] ckArgs) throws Exception {
                String stdin_text = \(JSONValue.string(programIOStdin(c)).javaLiteral);
                String expected = \(JSONValue.string(programIOExpected(c)).javaLiteral);
                ProcessBuilder ckBuilder = new ProcessBuilder("java", ckArgs[0]);
                ckBuilder.redirectInput(new java.io.File("\(stdinFile)"));
                Process ckProcess = ckBuilder.start();
                byte[] ckOutBytes = ckProcess.getInputStream().readAllBytes();
                byte[] ckErrBytes = ckProcess.getErrorStream().readAllBytes();
                int ckCode = ckProcess.waitFor();
                String ckPrinted = new String(ckOutBytes, java.nio.charset.StandardCharsets.UTF_8);
                String ckStderr = new String(ckErrBytes, java.nio.charset.StandardCharsets.UTF_8);
                if (ckCode != 0) {
                    ck.failed("\(GeneratedMessage.unexpectedException)\\n"
                        + "\(GeneratedMessage.input)" + ck.format(stdin_text) + "\\n"
                        + "\(GeneratedMessage.got)" + ck.format(ckNormalize(ckPrinted)) + "\\n"
                        + "\(GeneratedMessage.error)the program exited with status " + ckCode
                        + (ckStderr.isEmpty() ? "" : ": " + ckNormalize(ckStderr)));
                }
                \(compare)
                if (!ckOk) {
                    ck.failed("\(GeneratedMessage.wrongOutput)\\n"
                        + "\(GeneratedMessage.input)" + ck.format(stdin_text) + "\\n"
                        + "\(GeneratedMessage.expected)\(programIOExpectedPrefix(comparison))" + ck.format(expected) + "\\n"
                        + "\(GeneratedMessage.got)" + ck.format(ckNormalize(ckPrinted)));
                }
                ck.passed("Printed the expected output");
            }
        }
        """
    return """
        #!/bin/sh
        # Generated by Chickadee — do not edit. This wrapper runs the
        # submission as a whole program (java in source-file mode) with the
        # case's standard input, and grades what it printed under the
        # ordinary shell-script contract.
        student_file=""
        if [ -f .chickadee_student_module ]; then
            student_file=$(cat .chickadee_student_module)
        fi
        if [ ! -f "$student_file" ]; then
            for candidate in *.java; do
                case "$candidate" in
                    *test_*|_ck_inputs.java|CkProgram_*) ;;
                    *) student_file="$candidate"; break ;;
                esac
            done
        fi
        if [ ! -f "$student_file" ]; then
            echo "No Java submission file was found to run." 1>&2
            exit 2
        fi
        printf '%s' \(shellSingleQuoted(programIOStdin(c))) > \(shellSingleQuoted(stdinFile))
        cat > \(shellSingleQuoted("\(className).java")) <<'\(generatedSourceHeredocDelimiter)'
        \(checker)
        \(generatedSourceHeredocDelimiter)
        if ! javac -encoding UTF-8 -cp . -d . \(className).java test_runtime.java 2>.ck_build_log; then
            cat .ck_build_log 1>&2
            exit 2
        fi
        ck_out=$(java -ea -cp . \(className) "$student_file")
        ck_rc=$?
        if ! printf '%s\\n' "$ck_out" | grep -q '^CK_SENTINEL$'; then
            echo "The test did not run to completion." 1>&2
            exit 2
        fi
        printf '%s\\n' "$ck_out" | grep -v '^CK_SENTINEL$'
        exit $ck_rc
        """ + "\n"
}
