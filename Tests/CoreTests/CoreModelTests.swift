import Testing
import Foundation
@testable import Core

struct CoreModelTests {

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

    @Test(arguments: [TestStatus.pass, .fail, .error, .timeout])
    func testStatusRoundTrip(status: TestStatus) throws {
        let data = try encoder.encode(status)
        let decoded = try decoder.decode(TestStatus.self, from: data)
        #expect(status == decoded)
    }

    // MARK: - TestTier

    @Test(arguments: [TestTier.pub, .release, .secret])
    func testTierRoundTrip(tier: TestTier) throws {
        let data = try encoder.encode(tier)
        let decoded = try decoder.decode(TestTier.self, from: data)
        #expect(tier == decoded)
    }

    @Test(arguments: zip(
        [TestTier.pub, .release, .secret],
        ["public",     "release", "secret"]
    ))
    func testTierRawValue(tier: TestTier, expectedRaw: String) {
        #expect(tier.rawValue == expectedRaw)
    }

    // MARK: - GradingMode

    @Test func gradingModeDefaultsWorkerWhenAbsent() throws {
        let json = #"{ "schemaVersion": 1 }"#.data(using: .utf8)!
        let manifest = try decoder.decode(TestProperties.self, from: json)
        #expect(manifest.gradingMode == .worker)
    }

    @Test(arguments: zip(
        [
            #"{ "schemaVersion": 1, "gradingMode": "browser" }"#,
            #"{ "schemaVersion": 1, "gradingMode": "worker"  }"#
        ],
        [GradingMode.browser, GradingMode.worker]
    ))
    func gradingModeExplicit(json: String, expected: GradingMode) throws {
        let manifest = try decoder.decode(TestProperties.self, from: json.data(using: .utf8)!)
        #expect(manifest.gradingMode == expected)
    }

    @Test(arguments: [GradingMode.browser, .worker])
    func gradingModeRoundTrip(mode: GradingMode) throws {
        let data = try encoder.encode(mode)
        let decoded = try decoder.decode(GradingMode.self, from: data)
        #expect(mode == decoded)
    }

    // MARK: - TestProperties (no Makefile)

    @Test func testPropertiesRoundTrip() throws {
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
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.gradingMode == .worker)
        #expect(manifest.requiredFiles == ["warmup.py"])
        #expect(manifest.testSuites.count == 2)
        #expect(manifest.testSuites[0].script == "test_bit_count.sh")
        #expect(manifest.testSuites[0].tier == .pub)
        #expect(manifest.timeLimitSeconds == 10)
        #expect(manifest.makefile == nil)

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestProperties.self, from: reencoded)
        #expect(manifest == redecoded)
    }

    // MARK: - TestProperties (with Makefile)

    @Test func testPropertiesWithMakefileRoundTrip() throws {
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
        #expect(manifest.makefile != nil)
        #expect(manifest.makefile?.target == "build")

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestProperties.self, from: reencoded)
        #expect(manifest == redecoded)
    }

    @Test func testPropertiesWithDefaultMakeTarget() throws {
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
        #expect(manifest.makefile != nil)
        #expect(manifest.makefile?.target == nil)  // bare `make`, no target
    }

    // MARK: - TestSuiteEntry dependsOn

    @Test func testSuiteEntryDefaultsEmptyDependsOn() throws {
        let json = #"{ "tier": "public", "script": "test_foo.sh" }"#.data(using: .utf8)!
        let entry = try decoder.decode(TestSuiteEntry.self, from: json)
        #expect(entry.dependsOn == [])
    }

    @Test func testSuiteEntryWithDependsOnRoundTrip() throws {
        let json = #"{ "tier": "release", "script": "test_bar.sh", "dependsOn": ["test_foo.sh"] }"#
            .data(using: .utf8)!
        let entry = try decoder.decode(TestSuiteEntry.self, from: json)
        #expect(entry.script == "test_bar.sh")
        #expect(entry.dependsOn == ["test_foo.sh"])

        let reencoded = try encoder.encode(entry)
        let redecoded = try decoder.decode(TestSuiteEntry.self, from: reencoded)
        #expect(entry == redecoded)
    }

    @Test func testPropertiesWithDependencyChainRoundTrip() throws {
        let json = """
        {
          "schemaVersion": 1,
          "gradingMode": "worker",
          "testSuites": [
            { "tier": "public",  "script": "test_build.sh" },
            { "tier": "public",  "script": "test_unit_a.sh",  "dependsOn": ["test_build.sh"] },
            { "tier": "release", "script": "test_unit_b.sh",  "dependsOn": ["test_build.sh"] }
          ],
          "timeLimitSeconds": 10
        }
        """.data(using: .utf8)!

        let manifest = try decoder.decode(TestProperties.self, from: json)
        #expect(manifest.testSuites.count == 3)
        #expect(manifest.testSuites[0].dependsOn == [])
        #expect(manifest.testSuites[1].dependsOn == ["test_build.sh"])
        #expect(manifest.testSuites[2].dependsOn == ["test_build.sh"])

        let reencoded = try encoder.encode(manifest)
        let redecoded = try decoder.decode(TestProperties.self, from: reencoded)
        #expect(manifest == redecoded)
    }

    // MARK: - TestOutcomeCollection

    @Test func testOutcomeCollectionRoundTrip() throws {
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
            warnings: ["Notebook renamed to .py was normalized before grading."],
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(collection)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        #expect(decoded.submissionID == "sub_001")
        #expect(decoded.buildStatus == .passed)
        #expect(decoded.outcomes.count == 1)
        #expect(decoded.outcomes[0].testName == "test_foo")
        #expect(decoded.outcomes[0].isFirstPassSuccess)
        #expect(decoded.warnings == ["Notebook renamed to .py was normalized before grading."])
    }

    @Test func failedCollectionHasNoOutcomes() throws {
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
        #expect(decoded.buildStatus == .failed)
        #expect(decoded.outcomes.isEmpty)
        #expect(decoded.compilerOutput == "Script not found: test_foo.sh")
    }
}
