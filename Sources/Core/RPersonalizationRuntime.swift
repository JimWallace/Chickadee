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
}
