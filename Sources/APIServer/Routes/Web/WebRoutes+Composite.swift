// APIServer/Routes/Web/WebRoutes+Composite.swift
//
// GET /testsetups/:testSetupID/composite?since=<cursor> — the class
// composite's slot states and changed pixels as JSON
// (docs/class-composite.md, slice 5). `table-poll.js` polls it in its JSON
// mode for the canvas on the leaderboard page and in present mode, and
// `class-composite.js` draws what arrives.
//
// Staff read every slot, with the holders' handles on the ordinary page.
// Present mode passes `present=1` and reads no handles, because the room reads
// the wall. A student reads only their own slot: the full composite is for
// the projector. An ETag over the body makes an unchanged poll one 304.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func compositeSnapshot(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db),
            let activity = setup.decodedManifest()?.activity, activity.kind == .classComposite,
            let spec = activity.composite,
            let assignmentID = try await assignmentByTestSetupID(setupID, on: req.db)?.id
        else { throw Abort(.notFound) }

        let isStaff = try await isCourseStaff(user, inCourse: setup.courseID, db: req.db)
        if !isStaff {
            try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
        }
        // A composite that runs per lab group draws one group's image: the one
        // staff ask for, or the one a student's slot is in
        // (docs/lab-groups.md, slice 4).
        var groupID: UUID?
        if activity.isPerGroup {
            if isStaff {
                groupID = req.query[String.self, at: "group"].flatMap(UUID.init(uuidString:))
            } else if let userID = user.id {
                groupID = try await CompositePool.dealtSlot(assignmentID: assignmentID, userID: userID, on: req.db)?
                    .pool.groupID
            }
            guard groupID != nil else { throw Abort(.notFound) }
        }
        let snapshot = try await CompositeSnapshot.build(
            .init(
                assignmentID: assignmentID, testSetupID: setupID, courseID: setup.courseID, spec: spec,
                groupID: groupID),
            since: req.query[String.self, at: "since"].flatMap { Int64($0) },
            onlyUserID: isStaff ? nil : user.id,
            includeOwners: isStaff && req.query[String.self, at: "present"] != "1",
            on: req.db)
        // Sorted keys: the ETag is over the bytes, and an unsorted encoder
        // can order the same snapshot differently on each call.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(bytes: try encoder.encode(snapshot), encoding: .utf8) ?? "{}"
        return Response.conditionalJSON(json, for: req)
    }
}

extension Response {
    /// A JSON body with an ETag over its bytes, or a 304 when the client
    /// already holds those bytes. The same exchange `pollFragment` makes for
    /// HTML.
    static func conditionalJSON(_ json: String, for req: Request) -> Response {
        let etag = weakETag(for: json)
        if let notModified = notModified(etag: etag, for: req) { return notModified }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .eTag, value: etag)
        headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        headers.replaceOrAdd(name: .contentType, value: "application/json; charset=utf-8")
        return Response(status: .ok, headers: headers, body: .init(string: json))
    }
}
