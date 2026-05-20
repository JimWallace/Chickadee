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

/// Maps an instructor-typed Python type name to a runtime check expression
/// against `valueExpr` (the name of the Python variable holding the value to
/// test, e.g. `"result"` or `"actual"`).  Builtins use `isinstance` directly;
/// library types (pandas/numpy) are matched by walking the value's class MRO
/// by `__name__` so the generated test doesn't have to import those packages
/// at the top (matters for Pyodide grading, where `loadPackagesFromImports`
/// drives availability).  Unknown names fall through to the MRO walk so
/// student-defined classes and new library types work without a Swift edit.
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
        return "any(getattr(b, \"__name__\", \"\") == \"\(typeName)\" for b in type(\(valueExpr)).__mro__)"
    }
}
