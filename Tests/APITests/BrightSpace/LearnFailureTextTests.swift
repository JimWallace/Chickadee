// Tests/APITests/BrightSpace/LearnFailureTextTests.swift
//
// `learnFailureText` picks the sentence a staff page shows for a failed LEARN
// call by what the reader can do about it, and `BrightSpaceSyncError.httpStatus`
// is the fact it reads. These pin each branch, so a new error case or a
// status mapping cannot silently fall into the wrong advice.

import Testing

@testable import APIServer

@Suite struct LearnFailureTextTests {

    private struct OtherError: Error {}

    @Test func aNonLEARNErrorSaysLEARNDidNotAnswer() {
        #expect(
            learnFailureText(OtherError(), action: "read the grade book")
                == "Couldn't read the grade book: LEARN did not answer. Try again in a few minutes.")
    }

    @Test func notConfiguredPointsAtTheAdminSetup() {
        #expect(
            learnFailureText(BrightSpaceSyncError.notConfigured, action: "push grades")
                == "Couldn't push grades: LEARN is not set up on this server. An admin sets it up on the LEARN tab.")
    }

    @Test(arguments: [401, 403])
    func anAuthStatusAsksForReauthorization(_ status: Int) {
        let error = BrightSpaceSyncError.whoamiFailed(status: status, body: "denied")
        #expect(
            learnFailureText(error, action: "check the connection")
                == "Couldn't check the connection: LEARN refused the server's credentials. An admin can authorize again."
        )
    }

    @Test func notFoundPointsAtTheCourseLink() {
        let error = BrightSpaceSyncError.orgUnitLookupFailed(orgUnitID: "12345", status: 404)
        #expect(
            learnFailureText(error, action: "read the class list")
                == "Couldn't read the class list: LEARN has no course with this ID. Check the course's LEARN link.")
    }

    @Test func anotherStatusIsAGenericLEARNError() {
        let error = BrightSpaceSyncError.gradePushFailed(status: 500, body: "oops")
        #expect(
            learnFailureText(error, action: "push grades")
                == "Couldn't push grades: LEARN reported an error. Try again in a few minutes.")
    }

    /// A sync error that carries no status is not an auth or a lookup failure,
    /// so it gets the generic sentence, not the "not set up" one.
    @Test func aStatuslessSyncErrorIsAGenericLEARNError() {
        #expect(
            learnFailureText(BrightSpaceSyncError.missingPoints, action: "push grades")
                == "Couldn't push grades: LEARN reported an error. Try again in a few minutes.")
    }

    @Test func casesWithoutAStatusReportNil() {
        #expect(BrightSpaceSyncError.notConfigured.httpStatus == nil)
        #expect(BrightSpaceSyncError.userNotFound(orgDefinedId: "s1").httpStatus == nil)
        #expect(BrightSpaceSyncError.missingPoints.httpStatus == nil)
    }

    @Test func everyStatusCarryingCaseReportsItsStatus() {
        let cases: [(BrightSpaceSyncError, Int)] = [
            (.userLookupFailed(orgDefinedId: "s1", status: 400), 400),
            (.gradePushFailed(status: 401, body: ""), 401),
            (.whoamiFailed(status: 402, body: ""), 402),
            (.orgUnitLookupFailed(orgUnitID: "1", status: 403), 403),
            (.gradeObjectsFetchFailed(orgUnitID: "1", status: 404), 404),
            (.classlistFetchFailed(orgUnitID: "1", status: 405), 405),
            (.groupCategoriesFetchFailed(orgUnitID: "1", status: 406), 406),
            (.groupsFetchFailed(orgUnitID: "1", categoryID: "2", status: 407), 407),
            (.sectionsFetchFailed(orgUnitID: "1", status: 408), 408),
        ]
        for (error, status) in cases {
            #expect(error.httpStatus == status, "\(error)")
        }
    }
}
