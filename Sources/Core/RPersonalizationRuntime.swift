// Core/RPersonalizationRuntime.swift
//
// Base-R source snippets shared by the two places that need R personalization
// primitives: the injected grading runtime (test_runtime.R, via the worker's
// TestRuntimeSources) and the server-side R expression driver
// (PersonalizationEvaluator). One source of truth means the seed the driver
// binds and the seed a grading script reads are computed identically. Base R
// only — the grading image ships no CRAN packages.

public enum RPersonalizationRuntime {

    /// `chickadee_seed()` — a deterministic, base-R-safe integer derived from the
    /// per-student `CHICKADEE_ASSIGNMENT_SEED` (a 64-hex-char / 256-bit value).
    ///
    /// Base R has no arbitrary-precision integers, so the hex can't be
    /// `strtoi(..., 16)`'d directly (it overflows a 32-bit int). We fold the hex
    /// digits with Horner's method modulo `2^31 - 1` — every intermediate stays
    /// below `2^35`, safely inside a double — yielding `full_seed mod (2^31-1)`
    /// as an R integer. Deterministic per student and identical wherever it's
    /// called (driver + grading), so R stays self-consistent. Python assignments
    /// keep the full big-int seed; the two languages are distinct assignments,
    /// so cross-language equality is not required.
    public static let chickadeeSeedRSource = #"""
        chickadee_seed <- function() {
            hex <- tolower(gsub("[^0-9a-fA-F]", "", Sys.getenv("CHICKADEE_ASSIGNMENT_SEED", "")))
            if (!nzchar(hex)) return(0L)
            digits <- strtoi(strsplit(hex, "")[[1L]], 16L)
            modulus <- 2147483647            # 2^31 - 1; intermediates stay < 2^35
            acc <- 0
            for (d in digits) acc <- (acc * 16 + d) %% modulus
            as.integer(acc)
        }
        """#

    /// `chickadee_inputs()` — returns the per-student grading inputs the worker
    /// materialized into `_ck_inputs.R` (a `.ck_inputs <- list(...)` binding), or
    /// an empty list when none were delivered. The R mirror of a Python test
    /// reading `_ck["name"]` from `_ck_inputs.py`.
    public static let chickadeeInputsRSource = #"""
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
        """#

    /// Base-R JSON string encoder, shared by the personalization driver and the
    /// in-page auto-compute worker.
    ///
    /// Encodes char-by-char (`utf8ToInt`/`intToUtf8`) so it never trips over
    /// `gsub`'s replacement-string backslash rules — deparse output is
    /// quote-heavy and occasionally backslash-heavy, and this must round-trip
    /// through `JSONSerialization` on the Swift side.
    ///
    /// PUBLIC, and hoisted out of `PersonalizationEvaluator` where it was
    /// private, because a second consumer arrived. Note there is a THIRD R
    /// encoder in `TestRuntimeSources.swift` using exactly the `gsub` approach
    /// this one exists to avoid; it serves the grading runtime's own narrower
    /// payloads. Prefer this one for anything carrying deparse output.
    public static let chickadeeJSONStringRSource = #"""
        .ck_json_str <- function(x) {
            if (length(x) != 1L) x <- paste(as.character(x), collapse = "")
            x <- as.character(x)
            codes <- utf8ToInt(x)
            if (length(codes) == 0L) return("\"\"")
            out <- vapply(codes, function(cp) {
                if (cp == 34L) "\\\""
                else if (cp == 92L) "\\\\"
                else if (cp == 10L) "\\n"
                else if (cp == 13L) "\\r"
                else if (cp == 9L)  "\\t"
                else if (cp < 32L)  sprintf("\\u%04x", cp)
                else intToUtf8(cp)
            }, character(1L))
            paste0("\"", paste(out, collapse = ""), "\"")
        }
        """#
}
