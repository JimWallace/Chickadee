// APIServer/Utilities/PythonScriptHelpers.swift
//
// Shared helpers used by every Python-script renderer (pattern families,
// notebook checks).  Output bytes are content-addressed via spec_hash and
// feed TestSetupCache invalidation, so any change to these helpers shifts
// every generated script's hash and invalidates the runner-side cache.

import Core

/// Escapes a string for embedding inside a Python double-quoted literal in
/// rendered source.  Handles the characters that appear in family/check
/// metadata (backslash, double-quote, newline, control chars).
func escapeForPythonStringLiteral(_ s: String) -> String {
    var out = ""
    for ch in s.unicodeScalars {
        switch ch {
        case "\\": out += #"\\"#
        case "\"": out += #"\""#
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if ch.value < 0x20 {
                out += String(format: "\\x%02x", ch.value)
            } else {
                out.unicodeScalars.append(ch)
            }
        }
    }
    return out
}

/// Tier → filename prefix.  `public`/`release`/`secret` are the prefixes
/// the runner recognises when walking the test setup directory.
func tierFilenamePrefix(_ tier: TestTier) -> String {
    switch tier {
    case .pub: return "public"
    case .release: return "release"
    case .secret: return "secret"
    }
}
