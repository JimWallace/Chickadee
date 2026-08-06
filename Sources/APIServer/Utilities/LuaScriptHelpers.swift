// APIServer/Utilities/LuaScriptHelpers.swift
//
// Identifier and comment helpers for the Lua renderers, the counterpart to
// PythonScriptHelpers.swift and the `rIdentifier` / `rComment` pair in
// PatternFamilyRendererR.swift.

import Core
import Foundation

/// Lua's reserved words. A local cannot be named any of these, and unlike R
/// there is no quoting escape hatch — `local end = 1` is a syntax error with no
/// spelling that makes it legal.
private let luaReservedWords: Set<String> = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
]

/// True when `name` can be written directly as a Lua local.
///
/// Used by the authoring validator so an instructor is TOLD their variable name
/// is unusable, rather than having it silently renamed underneath them. R can
/// back-tick anything and Python's rules are close enough to Lua's that the
/// question rarely comes up; Lua is the language where a name like `my.value`
/// (perfectly fine in R) has no legal spelling at all.
public func isValidLuaIdentifier(_ name: String) -> Bool {
    guard let first = name.first else { return false }
    guard first.isLetter && first.isASCII || first == "_" else { return false }
    guard name.allSatisfy({ ($0.isLetter || $0.isNumber) && $0.isASCII || $0 == "_" }) else {
        return false
    }
    return !luaReservedWords.contains(name)
}

/// A name rendered as a Lua identifier, sanitised if it has to be.
///
/// The validator rejects unusable names upstream, so in normal operation this
/// is the identity. It sanitises rather than trapping because a renderer that
/// crashed on a name that slipped past validation would take down a save
/// instead of producing a test — and unparseable generated Lua is caught by
/// `everyGeneratedScriptParsesInItsOwnLanguage` either way.
func luaIdentifier(_ name: String) -> String {
    if isValidLuaIdentifier(name) { return name }
    var out = String(
        name.map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "_" })
    if out.isEmpty { out = "_" }
    if let first = out.first, first.isNumber { out = "_" + out }
    if luaReservedWords.contains(out) { out += "_" }
    return out
}

/// Flattens a string for safe use inside a one-line `--` comment.
///
/// A newline would end the comment and leave the remainder of the instructor's
/// text as executable Lua — the same reason `rComment` exists.
func luaComment(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}
