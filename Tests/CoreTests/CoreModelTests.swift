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

    // MARK: - TestStatus

    func testTestStatusRoundTrip() throws {
        for status in [TestStatus.pass, .fail, .error, .timeout] {
            let data = try encoder.encode(status)
            let decoded = try decoder.decode(TestStatus.self, from: data)
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

    // MARK: - GradingMode

    func testGradingModeDefaultsBrowserWhenAbsent() throws {
        let json = """
        { "schemaVersion": 1 }
        """.data(using: .utf8)!
        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertEqual(manifest.gradingMode, .browser)
    }

    func testGradingModeExplicitBrowser() throws {
        let json = """
        { "schemaVersion": 1, "gradingMode": "browser" }
        """.data(using: .utf8)!
        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertEqual(manifest.gradingMode, .browser)
    }

    func testGradingModeExplicitWorker() throws {
        let json = """
        { "schemaVersion": 1, "gradingMode": "worker" }
        """.data(using: .utf8)!
        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertEqual(manifest.gradingMode, .worker)
    }

    func testGradingModeRoundTrip() throws {
        for mode in [GradingMode.browser, .worker] {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(GradingMode.self, from: data)
            XCTAssertEqual(mode, decoded)
        }
    }

    // MARK: - TestProperties (no Makefile)

    func testTestPropertiesRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": ["warmup.py"],
          "testSuites": [
            { "tier": "public",  "script": "test_bit_count.sh"  },
            { "tier": "release", "script": "test_first_digit.sh" }
          ],
          "timeLimitSeconds": 10
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.gradingMode, .worker)
        XCTAssertEqual(manifest.requiredFiles, ["warmup.py"])
        XCTAssertEqual(manifest.testSuites.count, 2)
        XCTAssertEqual(manifest.testSuites[0].script, "test_bit_count.sh")
        XCTAssertEqual(manifest.testSuites[0].tier, .pub)
        XCTAssertEqual(manifest.timeLimitSeconds, 10)
        XCTAssertNil(manifest.makefile)

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestProperties.self, from: reencoded)
        XCTAssertEqual(manifest, redecoded)
    }

    // MARK: - TestProperties (with Makefile)

    func testTestPropertiesWithMakefileRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": ["warmup.py"],
          "testSuites": [
            { "tier": "public", "script": "test_bit_count.sh" }
          ],
          "timeLimitSeconds": 10,
          "makefile": { "target": "build" }
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertNotNil(manifest.makefile)
        XCTAssertEqual(manifest.makefile?.target, "build")

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestProperties.self, from: reencoded)
        XCTAssertEqual(manifest, redecoded)
    }

    func testTestPropertiesWithDefaultMakeTarget() throws {
        let json = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "requiredFiles": ["warmup.py"],
          "testSuites": [
            { "tier": "public", "script": "test_bit_count.sh" }
          ],
          "timeLimitSeconds": 10,
          "makefile": { "target": null }
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestProperties.self, from: json)
        XCTAssertNotNil(manifest.makefile)
        XCTAssertNil(manifest.makefile?.target)  // bare `make`, no target
    }

    // MARK: - TestOutcomeCollection

    func testTestOutcomeCollectionRoundTrip() throws {
        let outcome = TestOutcome(
            testName: "test_foo",
            testClass: nil,
            tier: .pub,
            status: .pass,
            shortResult: "passed",
            longResult: nil,
            executionTimeMs: 5,
            memoryUsageBytes: nil,
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
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(collection)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        XCTAssertEqual(decoded.submissionID, "sub_001")
        XCTAssertEqual(decoded.buildStatus, .passed)
        XCTAssertEqual(decoded.outcomes.count, 1)
        XCTAssertEqual(decoded.outcomes[0].testName, "test_foo")
        XCTAssertTrue(decoded.outcomes[0].isFirstPassSuccess)
    }

    func testFailedCollectionHasNoOutcomes() throws {
        let collection = TestOutcomeCollection(
            submissionID: "sub_002",
            testSetupID: "setup_001",
            attemptNumber: 1,
            buildStatus: .failed,
            compilerOutput: "Script not found: test_foo.sh",
            outcomes: [],
            totalTests: 0,
            passCount: 0,
            failCount: 0,
            errorCount: 0,
            timeoutCount: 0,
            executionTimeMs: 0,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(collection)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        XCTAssertEqual(decoded.buildStatus, .failed)
        XCTAssertTrue(decoded.outcomes.isEmpty)
        XCTAssertEqual(decoded.compilerOutput, "Script not found: test_foo.sh")
    }
}
