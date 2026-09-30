// APIServer/LTI/LTIPendingDeepLink.swift
//
// The facts of a verified deep-linking request (docs/lti-1-3.md "Deep
// Linking"), held in `APILTIDeepLinkRequest` between the launch and the
// instructor's choice. The return URL comes only from the platform-signed
// token, never from the browser, so the picker cannot be pointed at another
// site.

import Foundation

struct LTIPendingDeepLink: Equatable, Sendable {
    /// The custom parameter a returned link carries, naming the assignment.
    static let assignmentParameter = "assignment"

    let returnURL: String
    let data: String?
    let deploymentID: String
    let acceptMultiple: Bool
}
