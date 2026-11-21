// APIServer/Services/SystemAuditContext.swift
//
// The `AuditContext` for an event the server itself observes, with no request
// and no acting user: the row names no actor, address or user agent.

import Fluent
import Foundation
import Vapor

struct SystemAuditContext: AuditContext {
    let db: any Database
    let application: Application

    var logger: Logger { application.logger }
    var actingUserID: UUID? { nil }
    var auditActor: APIUser? { nil }
    var auditRemoteAddress: String? { nil }
    var auditUserAgent: String? { nil }
}
