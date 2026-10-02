// APIServer/Routes/Web/AccountRoutes+Handle.swift
//
// The student's one choice of class handle (docs/student-avatars.md §3).
//
//   POST /account/handle/:courseID → pick one of the two offered alternates
//
// While a handle is unlocked, the account page offers the current handle and
// two freshly drawn alternates, each beside the student's own bird.  All three
// are random, so a student owns the choice without being able to spell their
// name into it.  The alternates are not reserved: they are remembered in the
// session so that the POST can only pick one the page offered, and the unique
// index decides a race.  A pick locks the handle, and so does the first time a
// classmate sees it on a leaderboard.  After that the row reads "Your handle is
// set for this course", and the "Change handle" panel is gone.

import Core
import Fluent
import Vapor

/// One option in the "Choose a different handle" panel.
struct AccountHandleOption: Encodable {
    let handle: String
    let isCurrent: Bool
    /// The student's own bird, beside every option.
    let avatar: AvatarPresentation
}

/// The handle part of one account-page course row.
struct AccountHandleChoice: Encodable {
    /// True once the student can no longer choose.
    let isLocked: Bool
    /// The current handle first, then the alternates.  Empty when locked, or
    /// when the course has no unused handle left to offer.
    let options: [AccountHandleOption]
    let canChoose: Bool
    /// The student's pick was taken by somebody else first; the panel opens
    /// with two new alternates.
    let wasTaken: Bool
}

extension AccountRoutes {

    /// The session key holding the alternates offered for one enrollment.
    static func handleOfferKey(_ enrollmentID: UUID) -> String {
        "handleOffer.\(enrollmentID.uuidString)"
    }

    /// The alternates offered to this enrollment, reused while both are still
    /// available so that reloading the page does not deal a new pair, and
    /// drawn again when either has gone.
    static func handleOffer(
        for enrollment: APICourseEnrollment, taken: Set<String>, req: Request
    ) -> [String] {
        guard let enrollmentID = enrollment.id else { return [] }
        let key = handleOfferKey(enrollmentID)
        let stored = (req.session.data[key] ?? "").split(separator: "|").map(String.init)
        if stored.count == 2, stored.allSatisfy({ AvatarStore.isStillAvailable($0, taken: taken) }) {
            return stored
        }
        let fresh = AvatarStore.drawAlternates(taken: taken)
        req.session.data[key] = fresh.isEmpty ? nil : fresh.joined(separator: "|")
        return fresh
    }

    /// Each student enrollment's handle, materialized on first view, and its
    /// "Change handle" panel.  Keyed by course.
    static func studentHandles(
        enrollments: [APICourseEnrollment], spec: AvatarSpec, req: Request
    ) async throws -> (handles: [UUID: String], choices: [UUID: AccountHandleChoice]) {
        var handles: [UUID: String] = [:]
        var choices: [UUID: AccountHandleChoice] = [:]
        let takenCourseID = req.query[String.self, at: "handleTaken"]
        for enrollment in enrollments where enrollment.role == .student {
            // One roster read per enrollment, shared by the draw and the
            // alternates (#1759).
            guard let courseID = enrollment.course.id else { continue }
            var taken = try await AvatarStore.takenHandles(inCourse: courseID, on: req.db)
            guard let handle = try await AvatarStore.ensureHandle(for: enrollment, taken: taken, on: req.db)
            else { continue }
            taken.insert(handle)
            handles[courseID] = handle
            choices[courseID] = handleChoice(
                for: enrollment, handle: handle, spec: spec, taken: taken,
                wasTaken: takenCourseID == courseID.uuidString, req: req)
        }
        return (handles, choices)
    }

    /// The handle part of a course row on the account page.
    static func handleChoice(
        for enrollment: APICourseEnrollment, handle: String, spec: AvatarSpec, taken: Set<String>,
        wasTaken: Bool, req: Request
    ) -> AccountHandleChoice {
        guard enrollment.avatarHandleLockedAt == nil else {
            return AccountHandleChoice(isLocked: true, options: [], canChoose: false, wasTaken: false)
        }
        let alternates = handleOffer(for: enrollment, taken: taken, req: req)
        let avatar = AvatarPresentation(for: spec, size: .small, accessibility: .decorative)
        let options =
            [AccountHandleOption(handle: handle, isCurrent: true, avatar: avatar)]
            + alternates.map { AccountHandleOption(handle: $0, isCurrent: false, avatar: avatar) }
        return AccountHandleChoice(
            isLocked: false, options: options, canChoose: !alternates.isEmpty, wasTaken: wasTaken)
    }

    // MARK: - POST /account/handle/:courseID

    @Sendable
    func chooseHandle(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw Abort(.internalServerError) }
        guard let courseIDString = req.parameters.get("courseID"),
            let courseID = UUID(uuidString: courseIDString)
        else { throw Abort(.badRequest) }

        struct Body: Content { var handle: String }
        let body = try req.content.decode(Body.self)

        guard
            let enrollment = try await APICourseEnrollment.query(on: req.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .first(),
            enrollment.role == .student,
            enrollment.avatarHandle != nil,
            let enrollmentID = enrollment.id
        else { throw Abort(.notFound) }

        // Saving with the current handle selected keeps it, and does not
        // spend the one change.
        guard body.handle != enrollment.avatarHandle else { return req.redirect(to: "/account") }

        // Only a handle this page offered.  Anything else — a stale tab, a
        // hand-made POST — changes nothing.
        let key = Self.handleOfferKey(enrollmentID)
        let offered = (req.session.data[key] ?? "").split(separator: "|").map(String.init)
        guard offered.contains(body.handle) else { return req.redirect(to: "/account") }

        switch try await AvatarStore.chooseHandle(body.handle, for: enrollment, on: req.db) {
        case .chosen:
            req.session.data[key] = nil
            return req.redirect(to: "/account")
        case .locked:
            req.session.data[key] = nil
            return req.redirect(to: "/account")
        case .taken:
            // Drop the offer so the page deals two new alternates.
            req.session.data[key] = nil
            return req.redirect(to: "/account?handleTaken=\(courseIDString)")
        }
    }
}
