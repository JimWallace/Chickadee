// APIServer/LTI/LTIPendingDeepLink.swift
//
// A verified deep-linking request, held in the session between the launch
// and the instructor's choice (docs/lti-1-3.md "Deep Linking"). The return
// URL comes only from the platform-signed token, never from the browser, so
// the picker cannot be pointed at another site.

import Foundation
import Vapor

struct LTIPendingDeepLink: Equatable, Sendable {
    static let returnKey = "lti_dl_return"
    static let dataKey = "lti_dl_data"
    static let deploymentKey = "lti_dl_deployment"
    static let multipleKey = "lti_dl_multiple"
    /// Set once the course is known: at launch, or after `/lti/bind`.
    static let courseKey = "lti_dl_course"
    /// The custom parameter a returned link carries, naming the assignment.
    static let assignmentParameter = "assignment"

    let returnURL: String
    let data: String?
    let deploymentID: String
    let acceptMultiple: Bool

    func save(to session: Session) {
        session.data[Self.returnKey] = returnURL
        session.data[Self.dataKey] = data
        session.data[Self.deploymentKey] = deploymentID
        session.data[Self.multipleKey] = acceptMultiple ? "1" : nil
    }

    static func load(from session: Session) -> LTIPendingDeepLink? {
        guard let returnURL = session.data[returnKey], let deploymentID = session.data[deploymentKey] else {
            return nil
        }
        return LTIPendingDeepLink(
            returnURL: returnURL, data: session.data[dataKey], deploymentID: deploymentID,
            acceptMultiple: session.data[multipleKey] == "1")
    }

    static func clear(from session: Session) {
        for key in [returnKey, dataKey, deploymentKey, multipleKey, courseKey] {
            session.data[key] = nil
        }
    }
}
