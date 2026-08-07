// APIServer/Utilities/OctaveScriptHelpers.swift
//
// Identifier, comment and type-predicate helpers for the Octave renderers —
// the Octave siblings of LuaScriptHelpers.swift and the R helpers in
// PatternFamilyRendererR.swift.

import Core
import Foundation

/// Octave reserved words a sanitised identifier must dodge. Octave has no
/// R-style backtick quoting, so an invalid name cannot be spelled — it must be
/// rewritten.
private let octaveReservedWords: Set<String> = [
    "break", "case", "catch", "classdef", "continue", "do", "else", "elseif",
    "end", "end_try_catch", "end_unwind_protect", "endclassdef", "endenumeration",
    "endevents", "endfor", "endfunction", "endif", "endmethods", "endparfor",
    "endproperties", "endswitch", "endwhile", "enumeration", "events", "for",
    "function", "global", "if", "methods", "otherwise", "parfor", "persistent",
    "properties", "return", "switch", "try", "until", "unwind_protect",
    "unwind_protect_cleanup", "while",
]

/// True when `name` is a syntactic Octave identifier:
/// `[A-Za-z_][A-Za-z0-9_]*` and not a reserved word. (Unlike MATLAB, Octave
/// admits a leading underscore.)
func isValidOctaveIdentifier(_ name: String) -> Bool {
    guard let first = name.first, first.isASCII, first.isLetter || first == "_" else {
        return false
    }
    guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
        return false
    }
    return !octaveReservedWords.contains(name)
}

/// A usable Octave identifier for an instructor-supplied name.
///
/// The validator rejects unusable names upstream, so in normal operation this
/// is the identity. It sanitises rather than trapping because a renderer that
/// crashed on a name that slipped past validation would take down a save
/// instead of producing a test — and unparseable generated Octave is caught by
/// `everyGeneratedScriptParsesInItsOwnLanguage` either way.
func octaveIdentifier(_ name: String) -> String {
    if isValidOctaveIdentifier(name) { return name }
    var out = String(
        name.map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "_" })
    if out.isEmpty { out = "_" }
    if let first = out.first, first.isNumber { out = "_" + out }
    if octaveReservedWords.contains(out) { out += "_" }
    return out
}

/// Flattens a string for safe use inside a one-line `%` comment.
///
/// A newline would end the comment and leave the remainder of the instructor's
/// text as executable Octave — the same reason `rComment` and `luaComment`
/// exist.
func octaveComment(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

/// Maps an instructor-supplied type name to an Octave predicate. Python and R
/// type names are accepted too, so a family converted from either keeps
/// working; anything unrecognised falls back to an `isa` class check.
///
/// One asymmetry worth knowing: Octave's `isnumeric(true)` is false (logical
/// is its own class), so `bool` maps to `islogical` and the numeric names
/// exclude logicals — but `chickadee.equal(1, true)` still holds, because
/// `isequaln` compares those VALUES as equal. A type check asks a stricter
/// question than an equality check, deliberately.
func octaveTypeCheckExpression(typeName: String, valueExpr: String) -> String {
    switch typeName.lowercased() {
    case "numeric", "double", "float", "int", "integer", "number":
        return "isnumeric(\(valueExpr))"
    case "char", "character", "str", "string":
        return "ischar(\(valueExpr))"
    case "logical", "bool", "boolean":
        return "islogical(\(valueExpr))"
    case "cell", "list":
        return "iscell(\(valueExpr))"
    case "map", "dict", "containers.map":
        return "isa(\(valueExpr), \"containers.Map\")"
    case "struct":
        return "isstruct(\(valueExpr))"
    case "function", "callable", "function_handle":
        return "is_function_handle(\(valueExpr))"
    case "matrix":
        return "(isnumeric(\(valueExpr)) && ismatrix(\(valueExpr)))"
    case "vector":
        return "(isnumeric(\(valueExpr)) && isvector(\(valueExpr)))"
    case "null", "none", "empty":
        return "isempty(\(valueExpr))"
    case "any", "object":
        return "true"
    default:
        return "isa(\(valueExpr), \(JSONValue.string(typeName).octaveLiteral))"
    }
}
