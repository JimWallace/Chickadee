// Tests/APITests/Admin/DataExportAuditMetadataTests.swift
//
// A personal-data export includes the audit rows that name the user only in
// their metadata (a grade override, an extension, a per-student retest), and
// no other student's rows. The candidates are found in SQL by the user's name
// or id as a JSON string, then confirmed in Swift, so a username the JSON
// encoder escapes must still match.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5)))
struct DataExportAuditMetadataTests {

    private func entry(_ action: AuditAction, _ metadata: [String: String]) -> APIAuditLogEntry {
        APIAuditLogEntry(
            actorUsername: "export_instructor", action: action.rawValue,
            metadata: APIAuditLogEntry.encodeMetadata(metadata))
    }

    @Test(arguments: ["export_subject", "o'brien/lab"])
    func theExportHoldsTheRowsThatNameTheUserInMetadata(username: String) async throws {
        try await withTestApp(prefix: "chickadee-export-audit") { app in
            let subject = try await makeTestStudent(on: app, username: username)
            let subjectID = try subject.requireID().uuidString
            try await makeTestStudent(on: app, username: "export_other")

            try await entry(.gradeOverrideSet, ["student_username": username, "percent": "90"]).save(on: app.db)
            try await entry(.extensionGranted, ["subject_user_id": subjectID]).save(on: app.db)
            try await entry(.submissionRetestForStudent, ["subject_username": username]).save(on: app.db)
            // Another student's row, and a row whose other value merely
            // contains the name, stay out.
            try await entry(.gradeOverrideSet, ["student_username": "export_other"]).save(on: app.db)
            try await entry(.gradeOverrideSet, ["student_username": "export_other", "note": username])
                .save(on: app.db)

            let content = try await gatherDataExportContent(for: subject, on: app.db)
            #expect(
                Set(content.auditEntries.map(\.action))
                    == [
                        AuditAction.gradeOverrideSet.rawValue, AuditAction.extensionGranted.rawValue,
                        AuditAction.submissionRetestForStudent.rawValue,
                    ])
            #expect(content.auditEntries.count == 3)
        }
    }
}
