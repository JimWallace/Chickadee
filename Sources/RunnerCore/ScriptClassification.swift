// Shared, embedded-safe classification of "what interpreter runs this script?".
//
// This is the drift-prone decision behind the extensionless-Python dispatch bug
// (#754): a recognised extension wins, else the shebang, else a Python
// content-sniff. The native worker maps the result to a subprocess command; the
// browser runner (a follow-up) maps it to its capabilities. Pure + dependency-
// free so it compiles to wasm with the rest of RunnerCore.

public enum ScriptInterpreter: String, Sendable, Equatable {
    case python
    case sh
    case bash
    case zsh
    case ruby
    case perl
    case node
    case php
    case rscript
    /// No recognised extension, shebang, or Python-looking content. The caller
    /// decides the fallback (e.g. executable bit, else /bin/sh).
    case unknown
}

/// Classify a script by filename + its (leading) source text.
public func classifyScriptInterpreter(name: String, source: String) -> ScriptInterpreter {
    switch fileExtensionLowercased(name) {
    case "sh": return .sh
    case "bash": return .bash
    case "zsh": return .zsh
    case "py": return .python
    case "rb": return .ruby
    case "pl": return .perl
    case "js": return .node
    case "php": return .php
    case "r": return .rscript
    default: break  // no / unrecognised extension → shebang, then content
    }
    if let viaShebang = interpreterFromShebang(source) {
        return viaShebang
    }
    if looksLikePythonContent(source) {
        return .python
    }
    return .unknown
}

/// Map a `#!` shebang on the first line to an interpreter. Order matters:
/// "bash"/"zsh" are checked before "sh" (a substring of "bash").
private func interpreterFromShebang(_ source: String) -> ScriptInterpreter? {
    let firstLine = asciiLowercased(firstNonEmptyTrimmedLine(source))
    guard firstLine.hasPrefix("#!") else { return nil }
    if containsSubstring(firstLine, "python") { return .python }
    if containsSubstring(firstLine, "node") || containsSubstring(firstLine, "javascript") { return .node }
    if containsSubstring(firstLine, "ruby") { return .ruby }
    if containsSubstring(firstLine, "perl") { return .perl }
    if containsSubstring(firstLine, "bash") { return .bash }
    if containsSubstring(firstLine, "zsh") { return .zsh }
    if containsSubstring(firstLine, "sh") { return .sh }
    return nil
}

/// Do the first few non-comment lines look like Python?
private func looksLikePythonContent(_ source: String) -> Bool {
    let lines =
        source
        .split(separator: "\n" as Character, omittingEmptySubsequences: false)
        .map { trimHorizontalWhitespace(String($0)) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .prefix(5)
    guard !lines.isEmpty else { return false }
    return lines.contains { line in
        line.hasPrefix("import ")
            || line.hasPrefix("from ")
            || line.hasPrefix("def ")
            || line.hasPrefix("class ")
            || line.hasPrefix("if __name__ == ")
    }
}

// MARK: - Embedded-safe helpers (Swift stdlib only; file-private to avoid
// colliding with the similarly-named helpers in NotebookExtraction.swift).

/// Lowercased file extension, or "" when there's none (bare name or dotfile).
private func fileExtensionLowercased(_ name: String) -> String {
    let baseStart = name.lastIndex(of: "/").map { name.index(after: $0) } ?? name.startIndex
    let base = name[baseStart...]
    guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
    return asciiLowercased(String(base[base.index(after: dot)...]))
}

/// First non-empty line with leading BOM/whitespace trimmed.
private func firstNonEmptyTrimmedLine(_ source: String) -> String {
    let isLeading: (Character) -> Bool = {
        $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{feff}"
    }
    let trimmedLeading = source.drop(while: isLeading)
    return String(trimmedLeading.prefix { $0 != "\n" })
}

private func trimHorizontalWhitespace(_ s: String) -> String {
    let isHWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
    return String(s.drop(while: isHWS).reversed().drop(while: isHWS).reversed())
}

/// ASCII-only lowercase.  Shebang lines and file extensions are ASCII, so this
/// is behaviour-identical to `lowercased()` for the inputs we classify — but it
/// avoids linking Embedded Swift's Unicode case-folding tables into the wasm
/// binary (and sidesteps locale-style folding surprises like Turkish İ).
private func asciiLowercased(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        if scalar.value >= 0x41 && scalar.value <= 0x5A {  // A–Z → a–z
            out.unicodeScalars.append(Unicode.Scalar(UInt8(scalar.value + 0x20)))
        } else {
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Substring search without the string-processing module (absent in Embedded Swift).
private func containsSubstring(_ haystack: String, _ needle: String) -> Bool {
    if needle.isEmpty { return true }
    let hay = Array(haystack)
    let nee = Array(needle)
    if nee.count > hay.count { return false }
    var i = 0
    while i <= hay.count - nee.count {
        var j = 0
        while j < nee.count && hay[i + j] == nee[j] { j += 1 }
        if j == nee.count { return true }
        i += 1
    }
    return false
}
