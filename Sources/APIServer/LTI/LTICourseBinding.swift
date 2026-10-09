// APIServer/LTI/LTICourseBinding.swift
//
// Which Chickadee course an LMS context belongs to (docs/lti-1-3.md
// "Courses"). A course is bound by `(lti_platform_id, lti_context_id)`. An
// unbound context binds itself to the one course whose LEARN org unit ID
// equals the context ID, because D2L sends the org unit ID as `context.id`
// and that link is one an instructor already made on the LEARN tab.
//
// That match runs only while one platform is enabled. An org unit ID does
// not say which LMS it came from, and LMS course IDs are small integers, so
// with two platforms a context from the other LMS could match a LEARN org
// unit and enroll that LMS's instructors (docs/compliance/
// lti-audit-2026-10.md L-3).

import Fluent
import Foundation

enum LTICourseBinding {
    struct Match {
        let course: APICourse
        /// True when this call bound the context by org unit. The caller
        /// audits it.
        let boundByOrgUnit: Bool
    }

    /// The course bound to this context, binding it by org unit when exactly
    /// one unbound, unarchived course matches and this is the only enabled
    /// platform. Nil when neither applies.
    static func course(platformID: UUID, contextID: String, on db: Database) async throws -> Match? {
        if let bound = try await APICourse.query(on: db)
            .filter(\.$ltiPlatformID == platformID)
            .filter(\.$ltiContextID == contextID)
            .first()
        {
            return Match(course: bound, boundByOrgUnit: false)
        }
        let enabledPlatforms = try await APILTIPlatform.query(on: db).filter(\.$enabled == true).count()
        guard enabledPlatforms == 1 else { return nil }
        let byOrgUnit = try await APICourse.query(on: db)
            .filter(\.$brightspaceOrgUnitID == contextID)
            .filter(\.$ltiPlatformID == nil)
            .filter(\.$isArchived == false)
            .limit(2)
            .all()
        guard byOrgUnit.count == 1, let course = byOrgUnit.first else { return nil }
        try await bind(course, platformID: platformID, contextID: contextID, on: db)
        return Match(course: course, boundByOrgUnit: true)
    }

    /// Binds `course` to the context. The caller checks authority first.
    static func bind(_ course: APICourse, platformID: UUID, contextID: String, on db: Database) async throws {
        course.ltiPlatformID = platformID
        course.ltiContextID = contextID
        try await course.save(on: db)
    }
}
