// Shared, embedded-safe line splitting and trimming for RunnerCore.
//
// In Swift, "\r\n" is ONE `Character` (a single extended grapheme cluster), and
// it equals neither "\n" nor "\r". So `split(separator: "\n" as Character)`
// never splits CRLF text at all: a script whose stdout uses Windows line
// endings came back as a single "line", the JSON footer was never found, and
// the student's partial-credit `score` fell back to the exit-code default
// (#1457). Every line split in this module goes through `splitLines`, which
// works on Unicode scalars so that `\n`, `\r\n` and a lone `\r` each end a
// line, exactly as a POSIX tool or a text editor would read them.
//
// Stdlib only: no Foundation, no `components(separatedBy:)`, no string-
// processing module — this compiles to wasm with the rest of RunnerCore.
//
// The two trims at the foot of the file are the one copy of what three files
// each used to carry privately (#1724).

/// Split `s` into lines, keeping empty lines, so that `\n`, `\r\n` and a lone
/// `\r` each count as exactly one line break. The result always has one more
/// element than the number of line breaks (so `""` yields `[""]`), matching
/// the `omittingEmptySubsequences: false` shape the callers were written for.
func splitLines(_ s: String) -> [String] {
    var lines: [String] = []
    var current = ""
    var previousWasCarriageReturn = false
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\n":
            // The LF of a CRLF pair: the CR already ended the line.
            if !previousWasCarriageReturn {
                lines.append(current)
                current = ""
            }
            previousWasCarriageReturn = false
        case "\r":
            lines.append(current)
            current = ""
            previousWasCarriageReturn = true
        default:
            current.unicodeScalars.append(scalar)
            previousWasCarriageReturn = false
        }
    }
    lines.append(current)
    return lines
}

/// Whether `c` is a space, a tab, or a line break — including the CRLF
/// grapheme, which a plain `== "\n" || == "\r"` test misses.
func isWhitespaceOrLineBreak(_ c: Character) -> Bool {
    c.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
}

/// Trim leading and trailing spaces and tabs only, the way Foundation's
/// `.whitespaces` would. Line breaks stay, so a caller that works one line at
/// a time keeps its line.
func trimHorizontalWhitespace(_ s: String) -> String {
    let isHWS: (Character) -> Bool = { $0 == " " || $0 == "\t" }
    return String(s.drop(while: isHWS).reversed().drop(while: isHWS).reversed())
}

/// Trim leading and trailing spaces, tabs and line breaks, the way
/// Foundation's `.whitespacesAndNewlines` would.
func trimWhitespaceAndNewlines(_ s: String) -> String {
    let isWS: (Character) -> Bool = isWhitespaceOrLineBreak
    return String(s.drop(while: isWS).reversed().drop(while: isWS).reversed())
}
