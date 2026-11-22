// Core/TextLines.swift
//
// In Swift "\r\n" is ONE `Character` (one grapheme cluster), and it equals
// neither "\n" nor "\r". So `split(separator: "\n")` never splits CRLF text,
// and `components(separatedBy: "\n")` does not split it on Linux either. On
// macOS the second one does split it, through NSString, but it leaves a "\r"
// on each line. Text from a student, a notebook file or a feed can carry CRLF,
// so code outside RunnerCore that reads such text one line at a time goes
// through `textLines`. RunnerCore keeps its own embedded-safe `splitLines`
// (a contract path), with the same rule.

/// Splits `text` into lines, so that "\n", "\r\n" and a lone "\r" each end one
/// line, on every platform. Empty lines are kept: the result has one more
/// element than the number of line breaks, so "" gives `[""]` and "a\n" gives
/// `["a", ""]`, the shape of `components(separatedBy: "\n")` on LF text.
/// Other Unicode line separators stay in the text.
public func textLines(_ text: String) -> [String] {
    text.split(omittingEmptySubsequences: false) { $0 == "\r\n" || $0 == "\n" || $0 == "\r" }
        .map(String.init)
}
