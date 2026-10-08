// APIServer/Services/ServiceContext.swift
//
// What a service function needs from its caller (#2497). The validation
// service, the content-edit effects and the audit logger used to take a whole
// `Request`, so nothing without a request (a sweep, a background job) could
// call them. They now take one of these protocols. A `Request` conforms, so a
// route passes `req` as before, and a caller with no request can conform a
// type of its own.

import Fluent
import Foundation
import Vapor

/// The database, the logger and the application, plus the user who acts.
protocol ServiceContext {
    var db: any Database { get }
    var logger: Logger { get }
    var application: Application { get }
    /// The user the work is done for, when there is one. A web request gives
    /// its session user. An MCP request has none, because it authenticates
    /// with a bearer token, so an MCP caller passes the acting user explicitly.
    var actingUserID: UUID? { get }
}

/// A `ServiceContext` that can also say who did something, for an audit row.
protocol AuditContext: ServiceContext {
    /// The user the row names as the actor, or nil (a failed login).
    var auditActor: APIUser? { get }
    /// The client address, under the deployment's proxy trust rules.
    var auditRemoteAddress: String? { get }
    var auditUserAgent: String? { get }
}

extension Request: AuditContext {
    var actingUserID: UUID? { auth.get(APIUser.self)?.id }
    var auditActor: APIUser? { auth.get(APIUser.self) }
    var auditRemoteAddress: String? {
        clientIPAddress(from: self, trustForwardedFor: application.securityConfiguration.trustForwardedProto)
    }
    var auditUserAgent: String? { headers.first(name: "User-Agent") }
}
