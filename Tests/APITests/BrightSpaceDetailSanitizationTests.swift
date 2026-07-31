// Writer-side sanitization guards for BrightSpace sync error text
// (compliance audit F-2).
//
// The sync-log `detail` string and `BrightSpaceSyncError` descriptions flow
// into three admin-agent-visible places: `get_brightspace_sync_status` error
// samples, the `get_health_alerts` brightspace rule's `last_error`, and (via
// warning logs) the `query_logs` ring buffer. These tests pin the write-side
// guarantees: no institutional student identifier (orgDefinedId) in any
// description, D2L response bodies truncated, and the rejection detail built
// without the pushed grade value.

import Testing

@testable import APIServer

@Suite struct BrightSpaceDetailSanitizationTests {
    private let sentinelID = "SENTINEL-org-defined-id-20260731"

    @Test func userNotFoundDescriptionOmitsOrgDefinedId() {
        let error = BrightSpaceSyncError.userNotFound(orgDefinedId: sentinelID)
        #expect(!error.description.contains(sentinelID))
        #expect(!error.localizedDescription.contains(sentinelID))
    }

    @Test func userLookupFailedDescriptionOmitsOrgDefinedId() {
        let error = BrightSpaceSyncError.userLookupFailed(orgDefinedId: sentinelID, status: 404)
        #expect(!error.description.contains(sentinelID))
        #expect(error.description.contains("404"))
    }

    @Test func gradePushFailedDescriptionTruncatesBody() {
        let overLimit = String(
            repeating: "x", count: BrightSpaceSyncError.describedBodyLimit)
        let body = overLimit + "TRAILING-SENTINEL"
        let error = BrightSpaceSyncError.gradePushFailed(status: 400, body: body)
        #expect(error.description.contains("400"))
        #expect(!error.description.contains("TRAILING-SENTINEL"))
    }

    @Test func whoamiFailedDescriptionTruncatesBody() {
        let body =
            String(repeating: "y", count: BrightSpaceSyncError.describedBodyLimit)
            + "TRAILING-SENTINEL"
        let error = BrightSpaceSyncError.whoamiFailed(status: 500, body: body)
        #expect(!error.description.contains("TRAILING-SENTINEL"))
    }

    @Test func emptyBodyDescribesWithoutTrailingColon() {
        let error = BrightSpaceSyncError.gradePushFailed(status: 502, body: "")
        #expect(error.description == "BrightSpace grade push failed (HTTP 502)")
    }

    @Test func pushRejectionDetailCarriesNoStudentIdentifierOrGrade() {
        // The builder takes no points parameter at all — the grade cannot be
        // embedded. With a user-lookup error, the sanitized description keeps
        // the orgDefinedId out of the detail too.
        let detail = brightspacePushRejectionDetail(
            itemName: "Lab 3",
            maxPoints: "10.0",
            error: BrightSpaceSyncError.userNotFound(orgDefinedId: sentinelID))
        #expect(detail.contains("Lab 3"))
        #expect(detail.contains("rejected"))
        #expect(!detail.contains(sentinelID))
    }
}
