// APIServer/LTI/LTIDeepLinkingSettings.swift
//
// The `deep_linking_settings` claim of an `LtiDeepLinkingRequest`
// (docs/lti-1-3.md "Deep Linking"): where to send the selection, what the
// platform accepts, and an opaque `data` value to echo back.

import Foundation

struct LTIDeepLinkingSettings: Codable, Equatable, Sendable {
    let deepLinkReturnURL: String
    let acceptTypes: [String]?
    let acceptMultiple: Bool?
    let data: String?

    enum CodingKeys: String, CodingKey {
        case deepLinkReturnURL = "deep_link_return_url"
        case acceptTypes = "accept_types"
        case acceptMultiple = "accept_multiple"
        case data
    }

    /// The one content type Chickadee returns.
    static let resourceLinkType = "ltiResourceLink"

    var acceptsResourceLinks: Bool { acceptTypes?.contains(Self.resourceLinkType) == true }
}
