// LoadTest/SyntheticBrowserResult.swift
//
// The body of a simulated `POST /api/v1/submissions/browser-result`: the same
// three multipart fields `postBrowserResult` in `Public/browser-runner.js`
// sends. The collection passes every suite entry in the manifest, so the
// server does the full ingest a passing student costs: the submission and
// result writes, the leaderboard upsert and the records.

import Core
import Foundation

enum SyntheticBrowserResult {
    /// The smallest notebook the server's notebook merge accepts.
    static let emptyNotebook = Data(#"{"cells":[],"metadata":{},"nbformat":4,"nbformat_minor":5}"#.utf8)

    /// A passing collection for every entry in `manifest.testSuites`.
    /// `metric` gives each simulated student a distinct ranking value, so a
    /// ranked board has a full table to render.
    static func collection(manifest: TestProperties, testSetupID: String, metric: Double) -> TestOutcomeCollection {
        let outcomes = manifest.testSuites.map { entry in
            TestOutcome(
                testName: entry.script,
                testClass: nil,
                tier: entry.tier,
                status: .pass,
                shortResult: "passed",
                longResult: nil,
                points: entry.points,
                metric: metric,
                executionTimeMs: 5,
                memoryUsageBytes: nil,
                attemptNumber: 1,
                isFirstPassSuccess: true
            )
        }
        return TestOutcomeCollection(
            submissionID: "loadtest",
            testSetupID: testSetupID,
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: outcomes,
            totalTests: outcomes.count,
            passCount: outcomes.count,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 5 * outcomes.count,
            runnerVersion: "chickadee-loadtest",
            timestamp: Date()
        )
    }

    /// The multipart body and its `Content-Type`.
    static func multipart(
        collection: TestOutcomeCollection,
        notebook: Data,
        testSetupID: String,
        boundary: String = "chickadee-loadtest-\(UUID().uuidString)"
    ) throws -> (body: Data, contentType: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let collectionJSON = try encoder.encode(collection)

        var body = Data()
        func field(_ name: String, filename: String? = nil, contentType: String? = nil, value: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            var disposition = "Content-Disposition: form-data; name=\"\(name)\""
            if let filename { disposition += "; filename=\"\(filename)\"" }
            body.append(Data("\(disposition)\r\n".utf8))
            if let contentType { body.append(Data("Content-Type: \(contentType)\r\n".utf8)) }
            body.append(Data("\r\n".utf8))
            body.append(value)
            body.append(Data("\r\n".utf8))
        }
        field("collection", value: collectionJSON)
        field("notebook", filename: "submission.ipynb", contentType: "application/octet-stream", value: notebook)
        field("testSetupID", value: Data(testSetupID.utf8))
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
