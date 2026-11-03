// Tests/APITests/Infrastructure/InFilterChunkingTests.swift
//
// Follow-up to #2764: every `~~` (SQL IN) filter whose list grows with the
// data binds at most `inFilterChunkSize` values per query. Pins the helper and
// one call site whose list crosses a chunk boundary.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InFilterChunkingTests {

    @Test func anEmptyListGivesNoChunks() {
        #expect(chunkedForInFilter([String]()).isEmpty)
    }

    @Test(arguments: [1, inFilterChunkSize])
    func aListThatFitsIsOneChunk(count: Int) {
        let items = Array(0..<count)
        #expect(chunkedForInFilter(items) == [items])
    }

    @Test(arguments: [inFilterChunkSize + 1, inFilterChunkSize * 2, inFilterChunkSize * 2 + 7])
    func aLongerListSplitsInOrderWithNoChunkOverTheLimit(count: Int) {
        let items = Array(0..<count)
        let chunks = chunkedForInFilter(items)
        #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= inFilterChunkSize })
        #expect(chunks.flatMap(\.self) == items)
        #expect(chunks.count == (count + inFilterChunkSize - 1) / inFilterChunkSize)
    }
}

@Suite(.serialized, .timeLimit(.minutes(5)))
struct AssignmentDeletionChunkingTests {

    /// An assignment with more submissions than one IN filter binds loses
    /// every submission and every result, not only the first chunk.
    @Test func deleteRemovesEverySubmissionAndResultAcrossChunks() async throws {
        try await withTestApp { app in
            let scenario = try await TestScenario.make(on: app, code: "CHUNK101", setupID: "setup_chunked_delete")
            let student = try await makeTestStudent(on: app, username: "student_chunked_delete")
            let userID = try student.requireID()
            let count = inFilterChunkSize + 1
            let submissions = (0..<count).map { index in
                APISubmission(
                    id: "sub_chunk_\(index)", testSetupID: "setup_chunked_delete",
                    zipPath: "/nonexistent/sub_chunk_\(index).ipynb", attemptNumber: index + 1,
                    status: "complete", filename: "sub_chunk_\(index).ipynb", userID: userID,
                    kind: APISubmission.Kind.student)
            }
            for chunk in chunkedForInFilter(submissions) {
                try await chunk.create(on: app.db)
            }
            let results = (0..<count).map { index in
                APIResult(id: "res_chunk_\(index)", submissionID: "sub_chunk_\(index)", source: "worker")
            }
            for chunk in chunkedForInFilter(results) {
                try await chunk.create(on: app.db)
            }

            let removed = try await app.db.transaction { db in
                try await AssignmentDeletion.deleteRows(of: scenario.assignment, on: db)
            }

            #expect(removed.submissionCount == count)
            let remainingSubmissions = try await APISubmission.query(on: app.db)
                .filter(\.$testSetupID == "setup_chunked_delete").count()
            #expect(remainingSubmissions == 0)
            #expect(try await APIResult.query(on: app.db).count() == 0)
        }
    }
}
