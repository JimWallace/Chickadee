// APIServer/Models/APILTIDeepLinkRequest.swift
//
// One verified deep-linking request, waiting for course staff to choose
// assignments (docs/lti-1-3.md "Deep Linking"). The launch writes the row and
// renders the picker; the picker form carries the ticket, and the choice
// consumes the row once.
//
// This replaces the session. The LMS shows the picker in a frame on its own
// page, and a browser does not send Chickadee's session cookie there, so the
// request must travel in the form. Only a hash of the ticket is stored, so a
// database read cannot answer a request. The return URL comes only from the
// platform-signed launch, never from the browser.

import Fluent
import Vapor

final class APILTIDeepLinkRequest: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "lti_deep_link_requests"

    /// Thirty minutes: long enough to choose from a long assignment list,
    /// short enough that a leaked ticket soon stops working.
    static let lifetime: TimeInterval = 1800

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 (base64url) of the ticket the picker form carries.
    @Field(key: "ticket_hash")
    var ticketHash: String

    @Field(key: "platform_id")
    var platformID: UUID

    @Field(key: "course_id")
    var courseID: UUID

    /// The staff member the launch signed in. The choice is checked against
    /// this account's role in the course.
    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "return_url")
    var returnURL: String

    /// The platform's opaque `data`, echoed in the response.
    @OptionalField(key: "data")
    var data: String?

    @Field(key: "deployment_id")
    var deploymentID: String

    @Field(key: "accept_multiple")
    var acceptMultiple: Bool

    @Field(key: "expires_at")
    var expiresAt: Date

    /// Flipped once, atomically, by the choice that answers the request.
    @Field(key: "consumed")
    var consumed: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        ticketHash: String, platformID: UUID, courseID: UUID, userID: UUID, request: LTIPendingDeepLink,
        expiresAt: Date
    ) {
        self.ticketHash = ticketHash
        self.platformID = platformID
        self.courseID = courseID
        self.userID = userID
        self.returnURL = request.returnURL
        self.data = request.data
        self.deploymentID = request.deploymentID
        self.acceptMultiple = request.acceptMultiple
        self.expiresAt = expiresAt
        self.consumed = false
    }

    /// The request the platform signed.
    var request: LTIPendingDeepLink {
        LTIPendingDeepLink(
            returnURL: returnURL, data: data, deploymentID: deploymentID, acceptMultiple: acceptMultiple)
    }
}
