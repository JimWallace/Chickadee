// APIServer/Helpers/SessionIdleTimeoutTag.swift
//
// Leaf tag that outputs the configured idle-timeout in seconds.
// Used as: <meta name="session-idle-timeout-seconds" content="#sessionIdleTimeoutSeconds()">
//
// The client-side inactivity watchdog (idle-logout.js) reads this meta tag so
// the browser logs the user out at the same ceiling the server enforces
// (SessionIdleTimeoutMiddleware). Emits "0" when the gate is disabled, which
// tells the script to stay dormant.

import Leaf
import Vapor

struct SessionIdleTimeoutTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(0)
        guard let req = ctx.request else {
            return .string("0")
        }
        let seconds = Int(req.application.securityConfiguration.sessionIdleTimeoutSeconds)
        return .string(String(max(0, seconds)))
    }
}

/// Outputs the idle-warning lead time in seconds, used as:
/// <meta name="session-idle-warning-seconds" content="#sessionIdleWarningSeconds()">
///
/// idle-logout.js reads this to know how long before the ceiling to raise the
/// warning modal. "0" means no warning — log out straight at the ceiling.
struct SessionIdleWarningTag: UnsafeUnescapedLeafTag {
    func render(_ ctx: LeafContext) throws -> LeafData {
        try ctx.requireParameterCount(0)
        guard let req = ctx.request else {
            return .string("0")
        }
        let seconds = Int(req.application.securityConfiguration.sessionIdleWarningSeconds)
        return .string(String(max(0, seconds)))
    }
}
