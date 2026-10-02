// APIServer/LTI/LTIDeepLinkBindToken.swift
//
// Carries a deep-linking request from an unlinked LMS course through the
// "Link this LMS course" choice (docs/lti-1-3.md "Deep Linking"). The picker
// runs in the LMS frame, where the session cookie is not sent, so the facts
// the launch verified travel in the form, signed by the tool key, until the
// instructor picks a course. The choice then becomes an ordinary picker
// request with its own single-use ticket (`APILTIDeepLinkRequest`).
//
// The token needs no single use: what it authorises is binding a context to
// a course the same instructor teaches, which the route re-checks and which
// is refused once the context is bound to any other course.

import Foundation
import JWT

struct LTIDeepLinkBindToken: JWTPayload, Equatable {
    /// Short: the instructor chooses a course at once.
    static let lifetime: TimeInterval = 900

    /// Names what the token is for, so no other JWT the tool key signs (a
    /// deep-linking response) can stand in for it.
    static let audience = "chickadee:lti-deep-link-bind"

    let aud: AudienceClaim
    let exp: ExpirationClaim
    /// The account the launch resolved.
    let sub: SubjectClaim
    let platformID: UUID
    let contextID: String
    let contextTitle: String
    let returnURL: String
    let data: String?
    let deploymentID: String
    let acceptMultiple: Bool

    init(
        userID: UUID, platformID: UUID, contextID: String, contextTitle: String, request: LTIPendingDeepLink,
        now: Date = Date()
    ) {
        aud = AudienceClaim(value: Self.audience)
        exp = ExpirationClaim(value: now.addingTimeInterval(Self.lifetime))
        sub = SubjectClaim(value: userID.uuidString)
        self.platformID = platformID
        self.contextID = contextID
        self.contextTitle = contextTitle
        returnURL = request.returnURL
        data = request.data
        deploymentID = request.deploymentID
        acceptMultiple = request.acceptMultiple
    }

    /// The platform-signed request the token carries.
    var request: LTIPendingDeepLink {
        LTIPendingDeepLink(
            returnURL: returnURL, data: data, deploymentID: deploymentID, acceptMultiple: acceptMultiple)
    }

    var userID: UUID? { UUID(uuidString: sub.value) }

    func verify(using _: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
        try aud.verifyIntendedAudience(includes: Self.audience)
    }
}
