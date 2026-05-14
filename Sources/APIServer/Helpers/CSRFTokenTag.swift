// APIServer/Helpers/CSRFTokenTag.swift
//
// Leaf tag that outputs the raw CSRF token string (no HTML wrapper).
// Used as: <meta name="csrf-token" content="#csrfToken()">
//
// JavaScript reads the meta tag to include the token in fetch() headers,
// which is the standard approach for AJAX-heavy pages (same pattern as
// Rails, Django, and Laravel).

import CSRF
import Leaf
import Vapor

struct CSRFTokenTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(0)
        guard let req = ctx.request else {
            return LeafData.string("")
        }
        return LeafData.string(CSRF.createToken(from: req))
    }
}
