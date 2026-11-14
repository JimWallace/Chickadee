// Tests/APITests/BrightSpace/BrightSpaceSyncTypesTests.swift
//
// The non-actor types of the BrightSpace sync subsystem
// (`BrightSpaceSyncTypes.swift`): the configuration read from the
// environment, the error descriptions (with the audit F-2 rules: no student
// identifier, a D2L body cut to `describedBodyLimit`), and the grade-object
// wire shape. None of these needs a D2L host or a database.

import Foundation
import Testing

@testable import APIServer

@Suite struct BrightSpaceSyncTypesTests {

    private static let fullEnvironment: [String: String?] = [
        "BRIGHTSPACE_URL": "https://learn.example.edu/",
        "BRIGHTSPACE_APP_ID": "app-id",
        "BRIGHTSPACE_APP_KEY": "app-key",
        "BRIGHTSPACE_USER_ID": "user-id",
        "BRIGHTSPACE_USER_KEY": "user-key",
        "BRIGHTSPACE_SYNC_DEBOUNCE_SECS": nil,
    ]

    private static func environment(_ overrides: [String: String?]) -> [String: String?] {
        fullEnvironment.merging(overrides) { _, new in new }
    }

    // MARK: - Configuration

    @Test func aFullEnvironmentGivesAConfigWithTheTrailingSlashRemoved() async throws {
        let config = try await withTestEnvironment(Self.fullEnvironment) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        let resolved = try #require(config)
        #expect(resolved.baseURL == "https://learn.example.edu")
        #expect(resolved.appID == "app-id")
        #expect(resolved.appKey == "app-key")
        #expect(resolved.userID == "user-id")
        #expect(resolved.userKey == "user-key")
        #expect(resolved.debounceSecs == 90)
    }

    @Test func aBaseURLWithoutATrailingSlashIsKept() async throws {
        let config = try await withTestEnvironment(Self.environment(["BRIGHTSPACE_URL": "https://learn.example.edu"])) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        #expect(config?.baseURL == "https://learn.example.edu")
    }

    @Test(arguments: [
        "BRIGHTSPACE_URL", "BRIGHTSPACE_APP_ID", "BRIGHTSPACE_APP_KEY", "BRIGHTSPACE_USER_ID",
        "BRIGHTSPACE_USER_KEY",
    ])
    func aMissingRequiredVariableGivesNoConfig(_ key: String) async throws {
        let unset = try await withTestEnvironment(Self.environment([key: nil])) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        #expect(unset == nil)
        let blank = try await withTestEnvironment(Self.environment([key: "   "])) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        #expect(blank == nil)
    }

    @Test func aPositiveDebounceIsUsed() async throws {
        let config = try await withTestEnvironment(Self.environment(["BRIGHTSPACE_SYNC_DEBOUNCE_SECS": "30.5"])) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        #expect(config?.debounceSecs == 30.5)
    }

    @Test(arguments: ["0", "-5", "soon"])
    func aZeroNegativeOrUnreadableDebounceFallsBackToNinety(_ raw: String) async throws {
        let config = try await withTestEnvironment(Self.environment(["BRIGHTSPACE_SYNC_DEBOUNCE_SECS": raw])) {
            BrightSpaceSyncConfig.fromEnvironment()
        }
        #expect(config?.debounceSecs == 90)
    }

    // MARK: - Error descriptions

    @Test func eachErrorDescribesItsFailure() {
        let cases: [(BrightSpaceSyncError, String)] = [
            (.notConfigured, "BrightSpace sync is not configured (missing env vars)"),
            (.userNotFound(orgDefinedId: "20123456"), "BrightSpace user not found in the org unit classlist"),
            (.missingPoints, "No grade points available to push"),
            (
                .orgUnitLookupFailed(orgUnitID: "123", status: 404),
                "BrightSpace org unit lookup for '123' failed (HTTP 404)"
            ),
            (
                .gradeObjectsFetchFailed(orgUnitID: "123", status: 500),
                "BrightSpace grade-objects fetch for org unit '123' failed (HTTP 500)"
            ),
            (
                .classlistFetchFailed(orgUnitID: "123", status: 403),
                "BrightSpace classlist fetch for org unit '123' failed (HTTP 403)"
            ),
            (
                .groupCategoriesFetchFailed(orgUnitID: "123", status: 401),
                "BrightSpace group-categories fetch for org unit '123' failed (HTTP 401)"
            ),
            (
                .groupsFetchFailed(orgUnitID: "123", categoryID: "77", status: 502),
                "BrightSpace groups fetch for org unit '123' category '77' failed (HTTP 502)"
            ),
            (
                .sectionsFetchFailed(orgUnitID: "123", status: 503),
                "BrightSpace sections fetch for org unit '123' failed (HTTP 503)"
            ),
        ]
        for (error, description) in cases {
            #expect(error.description == description)
            #expect(error.errorDescription == description)
        }
    }

    /// Audit F-2: the student identifier stays in the associated value and
    /// out of the text that reaches logs and the admin MCP surface.
    @Test func aUserLookupFailureDoesNotDescribeTheStudentIdentifier() {
        let error = BrightSpaceSyncError.userLookupFailed(orgDefinedId: "20123456", status: 404)
        #expect(error.description == "BrightSpace user lookup failed (HTTP 404)")
        #expect(!error.description.contains("20123456"))
        #expect(!error.localizedDescription.contains("20123456"))
    }

    @Test func anEmptyBodyAddsNothingToTheDescription() {
        #expect(
            BrightSpaceSyncError.gradePushFailed(status: 400, body: "").description
                == "BrightSpace grade push failed (HTTP 400)")
        #expect(
            BrightSpaceSyncError.whoamiFailed(status: 401, body: "").description
                == "BrightSpace whoami failed (HTTP 401)")
    }

    @Test func aShortBodyIsDescribedWhole() {
        #expect(
            BrightSpaceSyncError.gradePushFailed(status: 400, body: "Invalid grade value").description
                == "BrightSpace grade push failed (HTTP 400): Invalid grade value")
        #expect(
            BrightSpaceSyncError.whoamiFailed(status: 403, body: "Forbidden").description
                == "BrightSpace whoami failed (HTTP 403): Forbidden")
    }

    @Test func aLongBodyIsCutToTheLimit() {
        let limit = BrightSpaceSyncError.describedBodyLimit
        let body = String(repeating: "a", count: limit) + "SECRET-TAIL"
        let push = BrightSpaceSyncError.gradePushFailed(status: 500, body: body).description
        #expect(push == "BrightSpace grade push failed (HTTP 500): " + String(repeating: "a", count: limit))
        #expect(!push.contains("SECRET-TAIL"))
        let whoami = BrightSpaceSyncError.whoamiFailed(status: 500, body: body).description
        #expect(whoami == "BrightSpace whoami failed (HTTP 500): " + String(repeating: "a", count: limit))
    }

    // MARK: - Grade-object wire shape

    @Test func aGradeObjectDecodesFromTheValenceShape() throws {
        let json = #"{"Id": 4021, "Name": "Lab 3", "MaxPoints": 10.0, "GradeType": "Numeric", "CanExceed": true}"#
        let decoded = try JSONDecoder().decode(GradeObjectJSON.self, from: Data(json.utf8))
        let object = decoded.asGradeObject
        #expect(object.id == "4021")
        #expect(object.name == "Lab 3")
        #expect(object.maxPoints == 10.0)
        #expect(object.gradeType == "Numeric")
        #expect(object.canExceed == true)
    }

    @Test func aGradeObjectWithoutTheOptionalFieldsDecodesToNil() throws {
        let json = #"{"Id": 7, "Name": "Final grade"}"#
        let object = try JSONDecoder().decode(GradeObjectJSON.self, from: Data(json.utf8)).asGradeObject
        #expect(object.id == "7")
        #expect(object.maxPoints == nil)
        #expect(object.gradeType == nil)
        #expect(object.canExceed == nil)
    }
}
