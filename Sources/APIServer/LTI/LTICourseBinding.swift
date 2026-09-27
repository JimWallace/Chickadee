// APIServer/LTI/LTICourseBinding.swift
//
// Which Chickadee course an LMS context belongs to (docs/lti-1-3.md
// "Courses"). A course is bound by `(lti_platform_id, lti_context_id)`. An
// unbound context binds itself to the one course whose LEARN org unit ID
// equals the context ID, because D2L sends the org unit ID as `context.id`
// and that link is one an instructor already made on the LEARN tab.

import Fluent
import Foundation

enum LTICourseBinding {
    /// The course bound to this context, binding it by org unit when exactly
    /// one unbound, unarchived course matches. Nil when neither applies.
    static func course(platformID: UUID, contextID: String, on db: Database) async throws -> APICourse? {
        if let bound = try await APICourse.query(on: db)
            .filter(\.$ltiPlatformID == platformID)
            .filter(\.$ltiContextID == contextID)
            .first()
        {
            return bound
        }
        let byOrgUnit = try await APICourse.query(on: db)
            .filter(\.$brightspaceOrgUnitID == contextID)
            .filter(\.$ltiPlatformID == nil)
            .filter(\.$isArchived == false)
            .limit(2)
            .all()
        guard byOrgUnit.count == 1, let course = byOrgUnit.first else { return nil }
        try await bind(course, platformID: platformID, contextID: contextID, on: db)
        return course
    }

    /// Binds `course` to the context. The caller checks authority first.
    static func bind(_ course: APICourse, platformID: UUID, contextID: String, on db: Database) async throws {
        course.ltiPlatformID = platformID
        course.ltiContextID = contextID
        try await course.save(on: db)
    }
}
