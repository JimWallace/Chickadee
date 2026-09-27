// APIServer/Models/APILTIIdentity.swift
//
// Links one LTI subject (the `sub` claim of one platform) to a Chickadee
// account (docs/lti-1-3.md "Identity"). A separate table, not the user's
// `authProvider`/`externalSubject`, so an account that signs in with DUO
// can also launch from an LMS without either sign-in replacing the other.

import Fluent
import Vapor

final class APILTIIdentity: Model, @unchecked Sendable {
    // @unchecked Sendable: only mutated within a request/DB context before save.
    static let schema = "lti_identities"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "platform_id")
    var platformID: UUID

    /// The platform's opaque `sub` value.
    @Field(key: "subject")
    var subject: String

    @Field(key: "user_id")
    var userID: UUID

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(platformID: UUID, subject: String, userID: UUID) {
        self.platformID = platformID
        self.subject = subject
        self.userID = userID
    }
}
