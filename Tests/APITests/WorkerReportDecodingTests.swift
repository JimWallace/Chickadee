// Tests/APITests/WorkerReportDecodingTests.swift
//
// The body of `POST /api/v1/worker/results`, decoded as the route decodes it.
// Pinned here: a wrapped report keeps every field the runner sent — above all
// `matches`, which an earlier decoder dropped so that no round-robin match row
// completed over HTTP — and a legacy bare collection is refused, since the
// deployment runner floor retired it (#1249).

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct WorkerReportDecodingTests {

    private let collection = TestOutcomeCollection(
        submissionID: "sub_decode",
        testSetupID: "setup_decode",
        attemptNumber: 1,
        buildStatus: .passed,
        compilerOutput: nil,
        outcomes: [],
        totalTests: 0,
        passCount: 0,
        failCount: 0,
        errorCount: 0,
        timeoutCount: 0,
        executionTimeMs: 10,
        runnerVersion: "shell-runner/1.0",
        timestamp: Date(timeIntervalSince1970: 0)
    )

    private func decode(_ data: Data) throws -> WorkerExecutionReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decodeWorkerReport(from: data, using: decoder)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    @Test func aWrappedReportKeepsItsMatches() throws {
        let matches = [
            MatchReport(
                opponentIdentity: "sub_b1", opponentSubmissionID: "sub_b1", seed: "seed-b",
                score: 1, metric: 3, won: true),
            MatchReport(
                opponentIdentity: "sub_c1", opponentSubmissionID: "sub_c1", seed: "seed-c",
                score: 0.5, metric: nil, won: false),
        ]
        let sent = WorkerExecutionReport(collection: collection, diagnostics: nil, matches: matches)

        let received = try decode(try encode(sent))

        let decodedMatches = try #require(received.matches)
        #expect(decodedMatches.map(\.opponentIdentity) == ["sub_b1", "sub_c1"])
        #expect(decodedMatches.map(\.seed) == ["seed-b", "seed-c"])
        #expect(decodedMatches.map(\.score) == [1, 0.5])
        #expect(decodedMatches.map(\.won) == [true, false])
        #expect(received.collection.submissionID == "sub_decode")
    }

    @Test func aWrappedReportWithoutMatchesDecodesThemAsNil() throws {
        let received = try decode(try encode(WorkerExecutionReport(collection: collection, diagnostics: nil)))
        #expect(received.matches == nil)
        #expect(received.diagnostics == nil)
    }

    @Test func anExplicitNullDiagnosticsIsAccepted() throws {
        let collectionJSON = try #require(String(data: try encode(collection), encoding: .utf8))
        let body = #"{"collection":\#(collectionJSON),"diagnostics":null}"#

        let received = try decode(Data(body.utf8))

        #expect(received.diagnostics == nil)
        #expect(received.collection.submissionID == "sub_decode")
    }

    @Test func aLegacyBareCollectionIsRefused() throws {
        let body = try encode(collection)
        #expect(throws: DecodingError.self) {
            try decode(body)
        }
    }

    @Test func aMalformedWrappedReportFailsToDecode() {
        let body = #"{"collection":{"submissionID":"sub_decode"}}"#
        #expect(throws: DecodingError.self) {
            try decode(Data(body.utf8))
        }
    }
}
