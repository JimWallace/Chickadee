// Tests/APITests/Admin/DataExportGenerationTests.swift
//
// `generateDataExport` called directly, without the request route. A
// failure marks only a pending row failed, with an operator-facing reason. A
// row in another state keeps its state. A generation cancelled by the
// shutdown drain writes nothing, so the row stays pending (the documented
// interrupted state). A new export replaces the old zip at the same path.
// `DataExportRoutesTests` covers the request route and a complete export.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class DataExportGenerationTests {

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-dexp-gen")
    }

    private func pendingExport(username: String) async throws -> (export: APIDataExport, userID: UUID) {
        let user = try await makeTestUser(on: app, username: username)
        let userID = try user.requireID()
        let export = APIDataExport(userID: userID)
        try await export.save(on: app.db)
        return (export, userID)
    }

    private func reload(_ export: APIDataExport) async throws -> APIDataExport {
        try #require(try await APIDataExport.find(export.requireID(), on: app.db))
    }

    @Test func aFailedGenerationMarksThePendingRowFailed() async throws {
        try await withApp(app) { app in
            let (export, _) = try await pendingExport(username: "dexp_gen_fail")
            let bystander = try await pendingExport(username: "dexp_gen_bystander")

            // No user has this ID, so the build stops at its first lookup.
            let missingUser = UUID()
            try await generateDataExport(exportID: export.requireID(), userID: missingUser, app: app)

            let failed = try await reload(export)
            #expect(failed.statusValue == .failed)
            #expect(failed.completedAt != nil)
            #expect(failed.zipPath == nil)
            let reason = try #require(failed.failureReason)
            #expect(reason == "User \(missingUser.uuidString) not found")
            #expect(reason.count <= 500)

            // The other user's row is untouched.
            let other = try await reload(bystander.export)
            #expect(other.statusValue == .pending)
            #expect(other.failureReason == nil)
        }
    }

    @Test func aFailureDoesNotOverwriteARowThatIsNoLongerPending() async throws {
        try await withApp(app) { app in
            let (export, _) = try await pendingExport(username: "dexp_gen_done")
            export.setStatus(.complete)
            export.zipPath = "/kept/by/the/test.zip"
            try await export.save(on: app.db)

            try await generateDataExport(exportID: export.requireID(), userID: UUID(), app: app)

            let kept = try await reload(export)
            #expect(kept.statusValue == .complete)
            #expect(kept.zipPath == "/kept/by/the/test.zip")
            #expect(kept.failureReason == nil)
        }
    }

    @Test func aFailureForARowThatIsGoneWritesNothing() async throws {
        try await withApp(app) { app in
            let bystander = try await pendingExport(username: "dexp_gen_gone")

            await generateDataExport(exportID: UUID(), userID: UUID(), app: app)

            #expect(try await APIDataExport.query(on: app.db).count() == 1)
            #expect(try await reload(bystander.export).statusValue == .pending)
        }
    }

    @Test func aCancelledGenerationLeavesTheRowPending() async throws {
        try await withApp(app) { app in
            let (export, userID) = try await pendingExport(username: "dexp_gen_cancel")
            let exportID = try export.requireID()

            // A child task added to a cancelled group starts cancelled, as a
            // generation does once the shutdown drain has cancelled it.
            await withTaskGroup(of: Void.self) { group in
                group.cancelAll()
                group.addTask {
                    await generateDataExport(exportID: exportID, userID: userID, app: app)
                }
            }

            let row = try await reload(export)
            #expect(row.statusValue == .pending)
            #expect(row.failureReason == nil)
            #expect(row.zipPath == nil)
            #expect(!FileManager.default.fileExists(atPath: app.dataExportsDirectory + "\(userID.uuidString).zip"))
        }
    }

    @Test func aNewExportReplacesTheOldZip() async throws {
        try await withApp(app) { app in
            let (export, userID) = try await pendingExport(username: "dexp_gen_replace")
            let finalPath = app.dataExportsDirectory + "\(userID.uuidString).zip"
            let stale = Data("stale export".utf8)
            #expect(FileManager.default.createFile(atPath: finalPath, contents: stale))

            try await generateDataExport(exportID: export.requireID(), userID: userID, app: app)

            let done = try await reload(export)
            #expect(done.statusValue == .complete)
            #expect(done.zipPath == finalPath)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: finalPath))
            #expect(bytes != stale)
            // A zip archive starts with the local file header "PK".
            #expect(bytes.prefix(2) == Data("PK".utf8))
            #expect(done.fileSizeBytes == bytes.count)
        }
    }

    @Test func theManagerCanBeReplaced() async throws {
        try await withApp(app) { app in
            let replacement = DataExportManager()
            app.dataExportManager = replacement
            #expect(app.dataExportManager === replacement)
            #expect(await app.dataExportManager.inFlightCount == 0)
        }
    }
}
