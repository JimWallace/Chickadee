import XCTest
@testable import Core

final class CoreModelTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - TestOutcomeStatus

    func testTestOutcomeStatusRoundTrip() throws {
        for status in [TestOutcomeStatus.pass, .fail, .error, .timeout] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(TestOutcomeStatus.self, from: data)
            XCTAssertEqual(status, decoded)
        }
    }

    // MARK: - TestTier

    func testTestTierRoundTrip() throws {
        for tier in [TestTier.pub, .release, .secret, .student] {
            let data = try encoder.encode(tier)
            let decoded = try decoder.decode(TestTier.self, from: data)
            XCTAssertEqual(tier, decoded)
        }
    }

    func testTestTierRawValues() {
        XCTAssertEqual(TestTier.pub.rawValue, "public")
        XCTAssertEqual(TestTier.release.rawValue, "release")
        XCTAssertEqual(TestTier.secret.rawValue, "secret")
        XCTAssertEqual(TestTier.student.rawValue, "student")
    }

    // MARK: - BuildLanguage

    func testBuildLanguageRoundTrip() throws {
        for lang in [BuildLanguage.java, .python] {
            let data = try encoder.encode(lang)
            let decoded = try decoder.decode(BuildLanguage.self, from: data)
            XCTAssertEqual(lang, decoded)
        }
    }

    // MARK: - RunnerResult (success)

    func testRunnerResultSuccessRoundTrip() throws {
        let json = """
        {
          "runnerVersion": "java-runner/1.0",
          "buildStatus": "passed",
          "compilerOutput": null,
          "executionTimeMs": 342,
          "outcomes": [
            {
              "testName": "testBitCount",
              "testClass": "PublicTests",
              "tier": "public",
              "status": "pass",
              "shortResult": "passed",
              "longResult": null,
              "executionTimeMs": 12,
              "memoryUsageBytes": null
            },
            {
              "testName": "testFirstDigit",
              "testClass": "ReleaseTests",
              "tier": "release",
              "status": "fail",
              "shortResult": "expected:<2> but was:<8>",
              "longResult": "AssertionFailedError at line 45",
              "executionTimeMs": 8,
              "memoryUsageBytes": null
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(RunnerResult.self, from: json)
        XCTAssertEqual(result.buildStatus, .passed)
        XCTAssertNil(result.compilerOutput)
        XCTAssertEqual(result.outcomes.count, 2)
        XCTAssertEqual(result.outcomes[0].testName, "testBitCount")
        XCTAssertEqual(result.outcomes[0].status, .pass)
        XCTAssertEqual(result.outcomes[1].status, .fail)

        // Round-trip
        let reencoded = try encoder.encode(result)
        let redecoded = try decoder.decode(RunnerResult.self, from: reencoded)
        XCTAssertEqual(result, redecoded)
    }

    // MARK: - RunnerResult (build failure)

    func testRunnerResultBuildFailureHasEmptyOutcomes() throws {
        let json = """
        {
          "runnerVersion": "java-runner/1.0",
          "buildStatus": "failed",
          "compilerOutput": "Warmup.java:12: error: ';' expected",
          "executionTimeMs": 0,
          "outcomes": []
        }
        """.data(using: .utf8)!

        let result = try decoder.decode(RunnerResult.self, from: json)
        XCTAssertEqual(result.buildStatus, .failed)
        XCTAssertEqual(result.compilerOutput, "Warmup.java:12: error: ';' expected")
        XCTAssertTrue(result.outcomes.isEmpty)
    }

    // MARK: - TestSetupManifest (Java)

    func testJavaManifestRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "language": "java",
          "requiredFiles": ["src/Warmup.java"],
          "testSuites": [
            { "tier": "public",     "className": "PublicTests",  "module": null },
            { "tier": "release", "className": "ReleaseTests", "module": null },
            { "tier": "student", "className": "StudentTests", "module": null }
          ],
          "limits": { "timeLimitSeconds": 10, "memoryLimitMb": 256 },
          "options": { "allowPartialCredit": false }
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestSetupManifest.self, from: json)
        XCTAssertEqual(manifest.language, .java)
        XCTAssertEqual(manifest.requiredFiles, ["src/Warmup.java"])
        XCTAssertEqual(manifest.testSuites.count, 3)
        XCTAssertEqual(manifest.testSuites[0].className, "PublicTests")
        XCTAssertNil(manifest.testSuites[0].module)
        XCTAssertEqual(manifest.limits.timeLimitSeconds, 10)
        XCTAssertFalse(manifest.options.allowPartialCredit)

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestSetupManifest.self, from: reencoded)
        XCTAssertEqual(manifest, redecoded)
    }

    // MARK: - TestSetupManifest (Python)

    func testPythonManifestRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "language": "python",
          "requiredFiles": ["warmup.py"],
          "testSuites": [
            { "tier": "public",     "module": "test_public",  "className": null },
            { "tier": "release", "module": "test_release", "className": null }
          ],
          "limits": { "timeLimitSeconds": 10, "memoryLimitMb": 256 },
          "options": { "allowPartialCredit": false }
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestSetupManifest.self, from: json)
        XCTAssertEqual(manifest.language, .python)
        XCTAssertEqual(manifest.testSuites[0].module, "test_public")
        XCTAssertNil(manifest.testSuites[0].className)
    }

    // MARK: - TestOutcomeCollection

    func testTestOutcomeCollectionRoundTrip() throws {
        let outcome = TestOutcome(
            testName: "testFoo",
            testClass: "PublicTests",
            tier: .pub,
            status: .pass,
            shortResult: "passed",
            longResult: nil,
            executionTimeMs: 5,
            memoryUsageBytes: nil,
            score: nil,
            attemptNumber: 1,
            isFirstPassSuccess: true
        )
        let collection = TestOutcomeCollection(
            submissionID: "sub_001",
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .passed,
            compilerOutput: nil,
            outcomes: [outcome],
            totalTests: 1,
            passCount: 1,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 100,
            runnerVersion: "java-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(collection)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        XCTAssertEqual(decoded.submissionID, "sub_001")
        XCTAssertEqual(decoded.buildStatus, .passed)
        XCTAssertEqual(decoded.outcomes.count, 1)
        XCTAssertEqual(decoded.outcomes[0].testName, "testFoo")
        XCTAssertTrue(decoded.outcomes[0].isFirstPassSuccess)
    }

    func testFailedCollectionHasNoOutcomes() throws {
        let collection = TestOutcomeCollection(
            submissionID: "sub_002",
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .failed,
            compilerOutput: "error: ';' expected",
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 0,
            runnerVersion: "java-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(collection)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        XCTAssertEqual(decoded.buildStatus, .failed)
        XCTAssertTrue(decoded.outcomes.isEmpty)
        XCTAssertEqual(decoded.compilerOutput, "error: ';' expected")
    }
}
