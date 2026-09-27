// APIServer/LTI/LTIValidatedLaunch.swift
//
// A launch that passed every `LTILaunchValidator` rule, reduced to the facts
// the launch route acts on.

import Core
import Foundation

struct LTIValidatedLaunch: Equatable, Sendable {
    enum MessageType: String, Equatable, Sendable {
        case resourceLink = "LtiResourceLinkRequest"
        case deepLinking = "LtiDeepLinkingRequest"
    }

    let messageType: MessageType
    let subject: String
    let nonce: String
    let deploymentID: String
    let courseRole: CourseRole
    /// Present on every resource-link launch; optional on deep linking.
    let context: LTILaunchClaims.Context?
    let resourceLink: LTILaunchClaims.ResourceLink?
    let name: String?
    let email: String?
    let custom: [String: JSONValue]
    /// Present on a deep-linking launch whose platform sent the settings.
    var deepLinkingSettings: LTIDeepLinkingSettings?
}
