// Tests/APITests/ClassRecordManifestTests.swift
//
// Unification A3: the class-record award logic (awardClassBadgesFor100Percent)
// iterates the manifest's authored classRecord achievements by dimension when
// present, instead of the hardcoded registry ids.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ClassRecordManifestTests {

    @Test func awardUsesManifestRecordsNotRegistry() async throws {
        try await withAssignmentRoutesApp { app in
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            // Manifest authors a single custom "fastest" record — the registry
            // defaults (trailblazer / speed_champion / minimalist) must NOT apply.
            let props = TestProperties(achievements: [
                Achievement(
                    id: "custom_speed", name: "Speedy", scope: .record,
                    reward: AchievementReward(type: .title, label: "Speedy"),
                    recordDimension: .fastest)
            ])
            let manifest = try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
            let setup = APITestSetup(
                id: "cr_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "cr_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)
            let student = try await arInsertStudent(username: "cr_student", on: app)
            let uid = try student.requireID()
            _ = try await arInsertSubmission(
                id: "cr_sub", testSetupID: "cr_setup", userID: uid, on: app)

            try await awardClassBadgesFor100Percent(
                testSetupID: "cr_setup", userID: uid, submissionID: "cr_sub",
                executionTimeMs: 100, attemptNumber: 1, on: app.db)

            let rows = try await APIClassAchievement.query(on: app.db)
                .filter(\.$testSetupID == "cr_setup")
                .all()
            #expect(
                rows.map(\.achievementID) == ["custom_speed"],
                "Only the manifest's record is awarded — not the registry defaults")
        }
    }
}
