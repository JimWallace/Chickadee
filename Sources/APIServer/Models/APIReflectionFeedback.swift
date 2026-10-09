// APIServer/Models/APIReflectionFeedback.swift
//
// AI-assisted feedback on one student's written reasoning for one assignment
// (docs/ai-assisted-feedback.md). An agent writes `draftText` through MCP
// `draft_feedback`; only course staff release it, on the staff review page,
// and only a released row is visible to the student. `userID` never leaves
// the server through MCP: the agent knows the student only by `handle`.

import Fluent
import Vapor

final class APIReflectionFeedback: Model, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "reflection_feedback"

    /// The stored lifecycle. "stale" is not stored: it is a draft or a release
    /// whose `submissionID` is no longer the student's latest submission.
    enum State: String, Codable, Sendable {
        case none
        case draft
        case released
        case discarded
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "handle")
    var handle: String

    /// The submission the draft was written against.
    @OptionalField(key: "submission_id")
    var submissionID: String?

    @OptionalField(key: "draft_text")
    var draftText: String?

    @Field(key: "state")
    var stateRaw: String

    @OptionalField(key: "drafted_at")
    var draftedAt: Date?

    /// The OAuth client name that wrote the draft, for attribution.
    @OptionalField(key: "drafted_by_client")
    var draftedByClient: String?

    @OptionalField(key: "reviewed_by_user_id")
    var reviewedByUserID: UUID?

    @OptionalField(key: "released_at")
    var releasedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    var state: State {
        get { State(rawValue: stateRaw) ?? .none }
        set { stateRaw = newValue.rawValue }
    }

    init() {}

    init(assignmentID: UUID, userID: UUID, handle: String) {
        self.assignmentID = assignmentID
        self.userID = userID
        self.handle = handle
        self.stateRaw = State.none.rawValue
    }
}
