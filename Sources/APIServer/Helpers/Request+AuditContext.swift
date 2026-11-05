// APIServer/Helpers/Request+AuditContext.swift
//
// A `Request` is an `AuditContext` (`Services/ServiceContext.swift`), so a
// route passes `req` to a service. Split from that file in #2775: Services/
// does not name `Request`.

import Core
import Fluent
import Foundation
import Vapor

extension Request: AuditContext {
    var actingUserID: UUID? { auth.get(APIUser.self)?.id }
    var auditActor: APIUser? { auth.get(APIUser.self) }
    var auditRemoteAddress: String? {
        clientIPAddress(from: self, trustForwardedFor: application.securityConfiguration.trustForwardedProto)
    }
    var auditUserAgent: String? { headers.first(name: "User-Agent") }

    /// The network part of the client's address (`ClientNetwork.prefix`), nil
    /// when unknown. Read from the LAST `X-Forwarded-For` entry, the address
    /// the deployment's own proxy saw: nginx appends it
    /// (`$proxy_add_x_forwarded_for`) after whatever the client sent, so the
    /// first entry is the client's to choose, and a student could name the
    /// room's network.
    var clientNetwork: String? {
        let forwarded = headers.first(name: "X-Forwarded-For")?.split(separator: ",").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let address =
            application.securityConfiguration.trustForwardedProto
            ? (forwarded ?? remoteAddress?.ipAddress) : remoteAddress?.ipAddress
        return address.flatMap(ClientNetwork.prefix(of:))
    }
}
