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

/// Maps an instructor-typed Python type name to a runtime type-check
/// expression against `valueExpr`.  Python builtins use `isinstance`
/// directly (`int` also rejects `bool`, which is an `int` subclass in
/// Python); pandas / numpy types and unknown names are matched by walking
/// the value's class MRO by name, so the generated test never imports the
/// library itself (matters for Pyodide grading, where
/// loadPackagesFromImports drives package availability).  Shared by the
/// pattern-family `.returnTypeCheck` renderer (`valueExpr` "result") and
/// the notebook-check `.variableExists` renderer (`valueExpr` "actual").
func pythonTypeCheckExpression(typeName: String, valueExpr: String) -> String {
    switch typeName {
    case "int": return "isinstance(\(valueExpr), int) and not isinstance(\(valueExpr), bool)"
    case "float": return "isinstance(\(valueExpr), float)"
    case "bool": return "isinstance(\(valueExpr), bool)"
    case "str": return "isinstance(\(valueExpr), str)"
    case "list": return "isinstance(\(valueExpr), list)"
    case "tuple": return "isinstance(\(valueExpr), tuple)"
    case "dict": return "isinstance(\(valueExpr), dict)"
    case "set": return "isinstance(\(valueExpr), set)"
    case "NoneType": return "\(valueExpr) is None"
    case "DataFrame":
        return #"any(getattr(b, "__name__", "") == "DataFrame" for b in type(\#(valueExpr)).__mro__)"#
    case "Series":
        return #"any(getattr(b, "__name__", "") == "Series" for b in type(\#(valueExpr)).__mro__)"#
    case "ndarray":
        return #"any(getattr(b, "__name__", "") == "ndarray" for b in type(\#(valueExpr)).__mro__)"#
    default:
        // Fallback: treat the name as a class to MRO-walk.  Catches
        // student-defined classes referenced by name and lets new
        // library types work without a Swift edit.
        return "any(getattr(b, \"__name__\", \"\") == \"\(typeName)\" for b in type(\(valueExpr)).__mro__)"
    }
}
