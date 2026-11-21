// Tests/APITests/BrightSpace/BrightSpaceOrgUnitVerificationTests.swift
//
// The halves of `BrightSpaceCourseBinding` that ask D2L, against a scripted
// D2L: verifying a bound org unit (found, not found, failed) and mapping
// assignments to grade items by name. `BrightSpaceCourseBindingTests`
// covers the paths that need no D2L.

import Fluent
import Foundation
import NIOCore
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class BrightSpaceOrgUnitVerificationTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-bs-binding")
    }

    private static let appCredentials = BrightSpaceAppCredentials(
        baseURL: "https://learn.test", appID: "app-id", appKey: "app-key", debounceSecs: 90)

    /// Answers the org-unit lookup with `orgUnit` and every other request
    /// with 404, so version discovery falls back.
    private func scriptOrgUnit(_ orgUnit: ScriptedValenceReply) {
        app.brightSpaceAppCredentials = Self.appCredentials
        _ = app.useScriptedValence { _, url, _ in
            url.contains("/orgstructure/") ? orgUnit : ScriptedValenceReply(.notFound)
        }
    }

    /// A course and an instructor whose stored key makes them a valid binder.
    private func courseAndBinder(code: String) async throws -> (APICourse, UUID) {
        let course = try await makeTestCourse(on: app, code: code)
        let instructor = try await makeTestUser(on: app, username: "binder_\(code.lowercased())", role: "instructor")
        let binder = try instructor.requireID()
        try await BrightSpaceCredentialStore.save(
            valenceUserID: "u", valenceUserKey: "k", identityName: "Prof Lee",
            capturedByUserID: binder, userID: binder, on: app.db)
        return (course, binder)
    }

    // MARK: - Verification

    @Test func aFoundOrgUnitIsVerifiedAndItsNameStored() async throws {
        try await withApp(app) { app in
            scriptOrgUnit(ScriptedValenceReply(.ok, #"{"Identifier":"12345","Name":"HLTH 230","Code":"H230"}"#))
            let (course, binder) = try await courseAndBinder(code: "BV1")

            let verification = try await BrightSpaceCourseBinding.bindOrgUnit(
                course: course, orgUnitID: "12345", binderUUID: binder, on: app.db, application: app)

            #expect(verification == .verified(name: "HLTH 230"))
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceOrgUnitID == "12345")
            #expect(reloaded.brightspaceOrgUnitName == "HLTH 230")
            #expect(reloaded.brightspaceSyncUserID == binder)
        }
    }

    @Test func aMissingOrgUnitIsReportedButTheBindingStays() async throws {
        try await withApp(app) { app in
            scriptOrgUnit(ScriptedValenceReply(.notFound))
            let (course, binder) = try await courseAndBinder(code: "BV2")

            let verification = try await BrightSpaceCourseBinding.bindOrgUnit(
                course: course, orgUnitID: "99999", binderUUID: binder, on: app.db, application: app)

            #expect(verification == .notFound)
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceOrgUnitID == "99999")
            #expect(reloaded.brightspaceOrgUnitName == nil)
        }
    }

    @Test func aFailedLookupIsReportedButTheBindingStays() async throws {
        try await withApp(app) { app in
            scriptOrgUnit(ScriptedValenceReply(.internalServerError, "{}"))
            let (course, binder) = try await courseAndBinder(code: "BV3")

            let verification = try await BrightSpaceCourseBinding.bindOrgUnit(
                course: course, orgUnitID: "12345", binderUUID: binder, on: app.db, application: app)

            let failed: Bool = if case .failed = verification { true } else { false }
            #expect(failed, "expected .failed, got \(verification)")
            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.brightspaceOrgUnitID == "12345")
            #expect(reloaded.brightspaceOrgUnitName == nil)
        }
    }

    // MARK: - Auto-map

    @Test func autoMapFillsOnlyEmptyMappingsByTrimmedCaseInsensitiveName() async throws {
        try await withApp(app) { app in
            // "Lab 1" twice: the first wins. A blank name maps nothing. The
            // titles differ, because a course's assignment slugs are unique.
            let gradeObjects = """
                [{"Id":101,"Name":"Lab 1"},{"Id":102,"Name":"  lab 2 "},\
                {"Id":103,"Name":"Lab 1"},{"Id":104,"Name":"   "},{"Id":105,"Name":"Lab 4"}]
                """
            app.brightSpaceAppCredentials = Self.appCredentials
            _ = app.useScriptedValence { _, url, _ in
                url.hasSuffix("/grades/") || url.contains("/grades/?")
                    ? ScriptedValenceReply(.ok, gradeObjects) : ScriptedValenceReply(.notFound)
            }
            let course = try await makeTestCourse(on: app, code: "BV4")
            let courseUUID = try course.requireID()
            func assignment(_ id: String, title: String, mappedTo existing: String? = nil) async throws -> APIAssignment
            {
                try await makeTestSetup(on: app, id: id, courseID: courseUUID)
                let made = try await makeTestAssignment(on: app, testSetupID: id, courseID: courseUUID, title: title)
                if let existing {
                    made.brightspaceGradeObjectID = existing
                    try await made.save(on: app.db)
                }
                return made
            }
            let lab1 = try await assignment("bvlab1", title: "Lab 1")
            let lab2 = try await assignment("bvlab2", title: " LAB 2")
            let lab3 = try await assignment("bvlab3", title: "Lab 3")
            let premapped = try await assignment("bvlab4", title: "Lab 4", mappedTo: "999")
            let client = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "u", userKey: "k"))

            let mapped = try await BrightSpaceCourseBinding.autoMap(
                courseUUID: courseUUID, orgUnitID: "12345", client: client, on: app.db, application: app)

            #expect(mapped == 2)
            func objectID(_ assignment: APIAssignment) async throws -> String? {
                try #require(try await APIAssignment.find(assignment.requireID(), on: app.db)).brightspaceGradeObjectID
            }
            #expect(try await objectID(lab1) == "101")
            #expect(try await objectID(lab2) == "102")
            #expect(try await objectID(lab3) == nil)
            #expect(try await objectID(premapped) == "999")

            let rerun = try await BrightSpaceCourseBinding.autoMap(
                courseUUID: courseUUID, orgUnitID: "12345", client: client, on: app.db, application: app)
            #expect(rerun == 0, "a second run changes nothing")
        }
    }

    @Test func autoMapThrowsWhenTheGradeBookCannotBeRead() async throws {
        try await withApp(app) { app in
            app.brightSpaceAppCredentials = Self.appCredentials
            _ = app.useScriptedValence { _, url, _ in
                url.contains("/grades/") ? ScriptedValenceReply(.forbidden, "{}") : ScriptedValenceReply(.notFound)
            }
            let course = try await makeTestCourse(on: app, code: "BV5")
            let client = BrightSpaceAPIClient(
                config: BrightSpaceSyncConfig(app: Self.appCredentials, userID: "u", userKey: "k"))

            await #expect {
                _ = try await BrightSpaceCourseBinding.autoMap(
                    courseUUID: try course.requireID(), orgUnitID: "12345", client: client,
                    on: app.db, application: app)
            } throws: { error in
                guard case .gradeObjectsFetchFailed(_, let status) = error as? BrightSpaceSyncError else {
                    return false
                }
                return status == 403
            }
        }
    }
}
