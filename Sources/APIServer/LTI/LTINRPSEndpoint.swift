// APIServer/LTI/LTINRPSEndpoint.swift
//
// The NRPS `namesroleservice` claim of a launch (docs/lti-1-3.md "Roster
// through NRPS"): where the context's membership list lives.

import Foundation

struct LTINRPSEndpoint: Codable, Equatable, Sendable {
    let contextMembershipsURL: String
    let serviceVersions: [String]?

    enum CodingKeys: String, CodingKey {
        case contextMembershipsURL = "context_memberships_url"
        case serviceVersions = "service_versions"
    }

    static let membershipScope = "https://purl.imsglobal.org/spec/lti-nrps/scope/contextmembership.readonly"
}
