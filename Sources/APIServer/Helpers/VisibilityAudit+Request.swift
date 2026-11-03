// APIServer/Helpers/VisibilityAudit+Request.swift
//
// The web door into `VisibilityAudit` (`Services/VisibilityAudit.swift`).
// Split from that file in #2775: Services/ does not name `Request`.

import Vapor

extension VisibilityAudit {
    static func web(_ req: Request, reason: String? = nil) -> VisibilityAudit {
        VisibilityAudit(context: req, origin: .web, reason: reason)
    }
}
