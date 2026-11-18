// Core/JSONReindenter.swift
//
// Pretty-prints one JSON document by adding whitespace and nothing else
// (docs/fhir-datasets-plan.md §5). The Data page shows an example FHIR resource
// this way.
//
// Why not `JSONSerialization` with `.prettyPrinted`: it does not keep key
// order (FHIR writes `resourceType` first, and a reader expects it there), and
// its output differs between macOS and Linux. This walks the original text,
// copies every string and number exactly, and only decides where line breaks
// and indentation go, so a document accepted as valid lays out the same on
// every platform. Validity is `JSONSerialization`'s answer, whose leniency may
// differ at the edges; the files this serves are FHIR resources that already
// passed `FHIRNdjsonProfile`.

import Foundation

/// Re-indents a JSON document without reordering or rewriting any value.
public enum JSONReindenter {

    /// `json` laid out with one member or element per line, indented by
    /// `indent` spaces per level, with `": "` after each key. Nil when `json`
    /// is not a valid JSON document. An empty object or array stays `{}` or
    /// `[]` on one line.
    public static func reindent(_ json: String, indent: Int = 2) -> String? {
        guard (try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])) != nil
        else {
            return nil
        }
        var writer = Writer(unit: String(repeating: " ", count: max(indent, 0)))
        let scalars = Array(json.unicodeScalars)
        var index = 0
        while index < scalars.count {
            index = writer.consume(scalars, at: index)
        }
        return writer.output
    }

    private struct Writer {
        let unit: String
        var output = ""
        var depth = 0

        /// Writes the token at `index` and returns the index after it.
        mutating func consume(_ scalars: [Unicode.Scalar], at index: Int) -> Int {
            let scalar = scalars[index]
            switch scalar {
            case "\"":
                return copyString(scalars, from: index)
            case "{", "[":
                let close: Unicode.Scalar = scalar == "{" ? "}" : "]"
                let next = Self.skipWhitespace(scalars, from: index + 1)
                if next < scalars.count, scalars[next] == close {
                    output.unicodeScalars.append(scalar)
                    output.unicodeScalars.append(close)
                    return next + 1
                }
                output.unicodeScalars.append(scalar)
                depth += 1
                newline()
                return index + 1
            case "}", "]":
                depth -= 1
                newline()
                output.unicodeScalars.append(scalar)
                return index + 1
            case ",":
                output.append(",")
                newline()
                return index + 1
            case ":":
                output.append(": ")
                return index + 1
            case " ", "\t", "\n", "\r":
                return index + 1
            default:
                // A number, `true`, `false` or `null`: copied as written.
                output.unicodeScalars.append(scalar)
                return index + 1
            }
        }

        /// Copies a string literal, quotes and escapes included, exactly.
        mutating func copyString(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
            output.unicodeScalars.append(scalars[start])
            var index = start + 1
            while index < scalars.count {
                let scalar = scalars[index]
                output.unicodeScalars.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    output.unicodeScalars.append(scalars[index + 1])
                    index += 2
                    continue
                }
                index += 1
                if scalar == "\"" { break }
            }
            return index
        }

        mutating func newline() {
            output.append("\n")
            output.append(String(repeating: unit, count: max(depth, 0)))
        }

        static func skipWhitespace(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
            var index = start
            while index < scalars.count, [" ", "\t", "\n", "\r"].contains(scalars[index]) { index += 1 }
            return index
        }
    }
}
