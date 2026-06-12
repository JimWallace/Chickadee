// APIServer/Helpers/AppVersionTag.swift
//
// Leaf tag that outputs the current app version string.
// Used as a cache-buster query parameter on static assets:
//   <link rel="stylesheet" href="/styles.css?v=#appVersion()">
//
// The version is read from ChickadeeVersion.current, so it automatically
// reflects the running build — no manual template updates needed on release.

import Core
import Leaf

struct AppVersionTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(0)
        return .string(ChickadeeVersion.current)
    }
}
