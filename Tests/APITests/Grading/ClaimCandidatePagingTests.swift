// Tests/APITests/Grading/ClaimCandidatePagingTests.swift
//
// The claim walk reads fresh student work in two pages: the first
// `ClaimCandidateLoader.firstPageSize` rows, then the rest of the scan cap
// only when nothing in the first page can be claimed. The second page starts
// from the first page's last time and leaves out the first page's rows, so
// equal submission times at the boundary are neither skipped nor read twice.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class ClaimCandidatePagingTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-claim-paging")
    }

    /// `count` pending fresh student submissions on one setup. Every row from
    /// `tiedFrom` on shares one submission time, so the page boundary falls
    /// inside a run of equal times.
    private func seed(count: Int, tiedFrom: Int, on app: Application) async throws -> [String] {
        let setupID = "setup_paging"
        let courseID = try await app.testCourseID()
        try await APITestSetup(
            id: setupID, manifest: TestManifests.workerOnePythonSuite,
            zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID
        ).save(on: app.db)
        let base = Date().addingTimeInterval(-3600)
        var ids: [String] = []
        for index in 0..<count {
            let id = String(cFormat: "sub_paging_%02d", index)
            try await APISubmission(
                id: id, testSetupID: setupID, zipPath: app.submissionsDirectory + "\(id).zip",
                attemptNumber: 1, status: SubmissionStatus.pending.rawValue
            ).save(on: app.db)
            let submittedAt = base.addingTimeInterval(Double(min(index, tiedFrom)))
            try await APISubmission.query(on: app.db).filter(\.$id == id)
                .set(\.$submittedAt, to: submittedAt).update()
            ids.append(id)
        }
        return ids
    }

    @Test func bothPagesTogetherReadEveryPendingRowOnce() async throws {
        try await withApp(app) { app in
            let pageSize = ClaimCandidateLoader.firstPageSize
            // Ties start before the boundary and run past it.
            let ids = try await seed(count: pageSize + 6, tiedFrom: pageSize - 3, on: app)

            let candidates = try await collectClaimCandidates(on: app.db)
            let read = candidates.compactMap { $0.0.id }
            #expect(read.count == ids.count)
            #expect(Set(read) == Set(ids))
            #expect(read.prefix(pageSize - 3) == ids.prefix(pageSize - 3), "rows before the ties stay in time order")
        }
    }

    @Test func aShortFirstPageReadsNoSecondPage() async throws {
        try await withApp(app) { app in
            let ids = try await seed(count: ClaimCandidateLoader.firstPageSize - 2, tiedFrom: .max, on: app)
            var loader = ClaimCandidateLoader(db: app.db)
            let first = try await loader.load(.freshStudent)
            let rest = try await loader.load(.freshStudentRest)
            #expect(first.compactMap { $0.0.id } == ids)
            #expect(rest.isEmpty)
        }
    }

    @Test func theScanCapStillBoundsBothPages() async throws {
        try await withApp(app) { app in
            _ = try await seed(count: ClaimCandidateLoader.scanLimit + 5, tiedFrom: .max, on: app)
            var loader = ClaimCandidateLoader(db: app.db)
            let first = try await loader.load(.freshStudent)
            let rest = try await loader.load(.freshStudentRest)
            #expect(first.count == ClaimCandidateLoader.firstPageSize)
            #expect(first.count + rest.count == ClaimCandidateLoader.scanLimit)
        }
    }
}
