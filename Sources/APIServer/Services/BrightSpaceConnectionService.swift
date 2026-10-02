// APIServer/Services/BrightSpaceConnectionService.swift
//
// The per-instructor LEARN connection: verifying a pasted Valence user key
// with D2L `whoami`, storing it, and designating which connected instructor
// a course pushes grades as. Functions over models, a database and the
// application, never a `Request`: the handlers in
// `InstructorLMSRoutes+BrightSpace.swift` decode the form, flash the
// outcome, write the audit entry and redirect. Moved out of the route
// extension in #1654 (slice 2), beside `BrightSpaceCredentialStore`, which
// already held the persistence half.

import Fluent
import Foundation
import Vapor

enum BrightSpaceConnectionService {

    /// Why a pasted key pair could not be connected.
    enum ConnectError: Error, Equatable {
        /// The server has no BrightSpace app credentials, so no key can be
        /// verified or used.
        case notConfigured
        /// D2L rejected the pair; the text is the transport's description.
        case credentialsRejected(String)
    }

    /// A stored connection: the LEARN identity D2L reported, and whether the
    /// active course adopted it as its sync identity.
    struct Connection: Equatable {
        let identity: String
        let claimedCourse: Bool
    }

    /// Why a connected instructor could not be made a course's sync identity.
    enum DesignateError: Error, Equatable {
        /// The instructor has no stored key, so grades could not push as them.
        case notConnected
    }

    /// Verifies the pair against D2L, stores it for `userUUID`, and — when
    /// the active course has no designated identity yet — makes this
    /// instructor it, so grades for the course push as their LEARN account.
    /// The default is "whoever connects"; `designate` reassigns it.
    static func connect(
        userUUID: UUID,
        valenceUserID: String,
        valenceUserKey: String,
        activeCourseUUID: UUID?,
        on db: Database,
        application: Application
    ) async throws -> Connection {
        guard let appCredentials = application.brightSpaceAppCredentials else {
            throw ConnectError.notConfigured
        }

        // Verify the pasted pair against D2L before persisting, so a bad paste
        // fails loudly here rather than silently breaking grade sync.
        let config = BrightSpaceSyncConfig(app: appCredentials, userID: valenceUserID, userKey: valenceUserKey)
        let candidate = BrightSpaceAPIClient(config: config)
        let who: BrightSpaceWhoAmI
        do {
            who = try await candidate.whoami(on: application)
        } catch {
            application.logger.warning(
                "BrightSpace connect: whoami verification failed: \(error.localizedDescription)")
            throw ConnectError.credentialsRejected(error.localizedDescription)
        }

        let identity = who.uniqueName.isEmpty ? who.displayName : "\(who.displayName) (\(who.uniqueName))"
        try await BrightSpaceCredentialStore.save(
            valenceUserID: valenceUserID,
            valenceUserKey: valenceUserKey,
            identityName: identity,
            capturedByUserID: userUUID,
            userID: userUUID,
            on: db
        )
        await application.brightSpaceClientRegistry.invalidate(userUUID.uuidString)

        var claimedCourse = false
        if let activeCourseUUID,
            let course = try await APICourse.find(activeCourseUUID, on: db),
            course.brightspaceSyncUserID == nil
        {
            course.brightspaceSyncUserID = userUUID
            try await course.save(on: db)
            claimedCourse = true
        }
        return Connection(identity: identity, claimedCourse: claimedCourse)
    }

    /// Makes a connected instructor the course's grade-sync identity — the
    /// "reassign" action that lets a connected co-instructor take over
    /// pushes for the course.
    static func designate(userUUID: UUID, course: APICourse, on db: Database) async throws {
        guard try await BrightSpaceCredentialStore.load(userID: userUUID, on: db) != nil else {
            throw DesignateError.notConnected
        }
        course.brightspaceSyncUserID = userUUID
        try await course.save(on: db)
    }

    /// Drops the instructor's stored key and cached client. Any course
    /// designating them as its sync identity then defers until someone
    /// reconnects — no grade is pushed with a stale key.
    static func disconnect(userUUID: UUID, on db: Database, application: Application) async throws {
        try await BrightSpaceCredentialStore.clear(userID: userUUID, on: db)
        await application.brightSpaceClientRegistry.invalidate(userUUID.uuidString)
    }
}
