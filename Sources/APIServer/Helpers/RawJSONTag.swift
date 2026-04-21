// APIServer/Helpers/RawJSONTag.swift
//
// Leaf tag that writes a context value as-is, without HTML entity escaping.
// Used when embedding pre-serialised JSON inside a `<script type="application/json">`
// block so `JSON.parse` can read the raw bytes — the default `#(...)` tag
// escapes `&`, `<`, `>`, and quotes, which breaks the JSON.
//
// Usage:
//   <script id="families" type="application/json">#rawJSON(patternFamiliesJSON)</script>
//
// Only pass values that are safe to emit verbatim (i.e. values the server
// itself produced via JSONEncoder).  Do not pass untrusted user input.

import Vapor
import Leaf

struct RawJSONTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(1)
        return LeafData.string(ctx.parameters[0].string ?? "")
    }
}
