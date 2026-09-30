// APIServer/LTI/LTIBindRoutes.swift
//
// Binds an LMS course to a Chickadee course (docs/lti-1-3.md "Courses").
// Reached only after an instructor launch from an unbound context: the
// launch signs the instructor in and leaves the context in the session.
//
//   GET  /lti/bind → lti-bind.leaf, the instructor's unbound courses
//   POST /lti/bind → bind the chosen course, then go to it
//
// Registered in the authenticated, CSRF-protected group: unlike the launch,
// this is an ordinary first-party form.

import Core
import Fluent
import Vapor

struct LTIBindRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.get("lti", "bind", use: bindPage)
        routes.post("lti", "bind", use: bind)
    }

    struct Pending {
        let platformID: UUID
        let contextID: String
        let contextTitle: String
    }

    @Sendable
    func bindPage(req: Request) async throws -> View {
        let pending = try Self.pending(req)
        let user = try req.auth.require(APIUser.self)
        let courses = try await Self.bindableCourses(for: user, on: req.db)
        return try await req.view.render(
            "lti-bind",
            LTIBindContext(
                currentUser: req.currentUserContext,
                contextTitle: pending.contextTitle,
                courses: courses.compactMap { course in
                    course.id.map {
                        LTIBindCourseOption(
                            id: $0.uuidString, code: course.code, name: course.name,
                            termLabel: course.term?.displayName)
                    }
                }))
    }

    @Sendable
    func bind(req: Request) async throws -> Response {
        struct Body: Content { var courseID: UUID }
        let pending = try Self.pending(req)
        let user = try req.auth.require(APIUser.self)
        let courseID = try req.content.decode(Body.self).courseID
        guard
            let course = try await Self.bindableCourses(for: user, on: req.db).first(where: { $0.id == courseID })
        else { throw Abort(.forbidden, reason: "You can link only a course you teach that is not linked yet.") }
        let alreadyBound =
            try await APICourse.query(on: req.db)
            .filter(\.$ltiPlatformID == pending.platformID)
            .filter(\.$ltiContextID == pending.contextID)
            .first() != nil
        guard !alreadyBound else {
            throw Abort(.conflict, reason: "This LMS course is already linked to a Chickadee course.")
        }
        try await LTICourseBinding.bind(
            course, platformID: pending.platformID, contextID: pending.contextID, on: req.db)
        await AuditLogger.record(
            action: .ltiCourseBound, targetType: .course, targetID: courseID.uuidString,
            metadata: ["course": course.code, "context_id": pending.contextID], courseID: courseID, on: req)
        req.session.data[LTIRoutes.pendingPlatformKey] = nil
        req.session.data[LTIRoutes.pendingContextKey] = nil
        req.session.data[LTIRoutes.pendingContextTitleKey] = nil
        req.session.data["activeCourseID"] = courseID.uuidString
        return req.redirect(to: "/")
    }

    /// The context the launch left in the session, or a 404 when there is none.
    static func pending(_ req: Request) throws -> Pending {
        guard
            let platform = req.session.data[LTIRoutes.pendingPlatformKey].flatMap(UUID.init(uuidString:)),
            let context = req.session.data[LTIRoutes.pendingContextKey]
        else { throw Abort(.notFound, reason: "There is no LMS course to link. Open the link from the LMS again.") }
        return Pending(
            platformID: platform, contextID: context,
            contextTitle: req.session.data[LTIRoutes.pendingContextTitleKey] ?? context)
    }

    /// Unarchived courses `user` teaches (every unarchived course for an
    /// admin) that are not bound to any LMS course yet.
    static func bindableCourses(for user: APIUser, on db: Database) async throws -> [APICourse] {
        var query = APICourse.query(on: db)
            .filter(\.$isArchived == false)
            .filter(\.$ltiPlatformID == nil)
        if !user.isAdmin {
            let taught = try await APICourseEnrollment.query(on: db)
                .filter(\.$userID == user.requireID())
                .filter(\.$roleRaw == CourseRole.instructor.rawValue)
                .all()
                .map(\.$course.id)
            guard !taught.isEmpty else { return [] }
            query = query.filter(\.$id ~~ taught)
        }
        return try await query.all().sorted(by: courseListPrecedes)
    }
}

struct LTIBindContext: Encodable {
    let currentUser: CurrentUserContext?
    let contextTitle: String
    let courses: [LTIBindCourseOption]
}

struct LTIBindCourseOption: Encodable {
    let id: String
    let code: String
    let name: String
    /// "Fall 2026", or nil when the course records no term. Two offerings
    /// of one course are told apart by it.
    let termLabel: String?
}
