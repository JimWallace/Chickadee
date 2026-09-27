// APIServer/LTI/LTIAGSEndpoint.swift
//
// The AGS `endpoint` claim of a launch (docs/lti-1-3.md "Grades through
// AGS"): the scopes the platform grants and where the course's line items
// live.

import Foundation

struct LTIAGSEndpoint: Codable, Equatable, Sendable {
    let scope: [String]?
    let lineItems: String?
    let lineItem: String?

    enum CodingKeys: String, CodingKey {
        case scope
        case lineItems = "lineitems"
        case lineItem = "lineitem"
    }

    static let lineItemScope = "https://purl.imsglobal.org/spec/lti-ags/scope/lineitem"
    static let scoreScope = "https://purl.imsglobal.org/spec/lti-ags/scope/score"

    /// The line-items URL, when the platform grants both scopes the AGS sweep
    /// needs: managing line items and posting scores.
    var usableLineItemsURL: String? {
        let granted = Set(scope ?? [])
        guard granted.contains(Self.lineItemScope), granted.contains(Self.scoreScope) else { return nil }
        return lineItems
    }
}
