// APIServer/Views/JSONIsland.swift
//
// A `<script type="application/json">` data island: server-made JSON that a
// page script reads with `JSON.parse(el.textContent)`.
//
// Elementary escapes text inside a script element, which would break the
// JSON, so the island writes it raw. The JSON can carry text an author wrote
// (a test name, a family label), so every `<` is written as `\u003c` first:
// no `</script>` or `<!--` can then end or change the script element, and
// `JSON.parse` reads the same value. A `<` outside a JSON string is not valid
// JSON, so the substitution never lands outside one.

import Elementary
import Foundation

struct JSONIsland: HTML {
    let id: String
    let json: String

    var body: some HTML {
        script(.id(id), .custom(name: "type", value: "application/json")) {
            HTMLRaw(Self.scriptSafe(json))
        }
    }

    /// `json` with every `<` written as the JSON escape `\u003c`.
    static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "<", with: "\\u003c")
    }
}
