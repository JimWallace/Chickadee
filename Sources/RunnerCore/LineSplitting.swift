// Shared, embedded-safe line splitting for RunnerCore.
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
