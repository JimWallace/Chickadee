import Foundation
import Testing

@testable import Core

// Tests for Core types with non-trivial Codable behaviour.
// Pure Codable round-trips are here; model logic is in CoreModelTests.swift.

struct CoreCodableTests {

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

    // MARK: - BuildStatus

    @Test(
        arguments: zip(
            [BuildStatus.passed, .failed, .skipped],
            ["passed", "failed", "skipped"]
        ))
    func buildStatusRawValue(status: BuildStatus, raw: String) {
        #expect(status.rawValue == raw)
    }

    @Test(arguments: [BuildStatus.passed, .failed, .skipped])
    func buildStatusRoundTrip(status: BuildStatus) throws {
        let data = try encoder.encode(status)
        let decoded = try decoder.decode(BuildStatus.self, from: data)
        #expect(decoded == status)
    }

    // MARK: - TestOutcome — custom decoder (points defaults to 1)

    @Test func testOutcomePointsDefaultsToOne() throws {
        let json = Data(
            """
            {
              "testName": "testFoo",
              "tier": "public",
              "status": "pass",
              "shortResult": "passed",
              "executionTimeMs": 42,
              "attemptNumber": 1,
              "isFirstPassSuccess": true
            }
            """.utf8)

        let outcome = try decoder.decode(TestOutcome.self, from: json)
        #expect(outcome.points == 1)
        #expect(outcome.testClass == nil)
        #expect(outcome.longResult == nil)
        #expect(outcome.memoryUsageBytes == nil)
    }

    @Test func testOutcomeExplicitPoints() throws {
        let json = Data(
            """
            {
              "testName": "testBar",
              "tier": "release",
              "status": "fail",
              "shortResult": "wrong answer",
              "longResult": "expected 42, got 0",
              "points": 3,
              "executionTimeMs": 10,
              "attemptNumber": 2,
              "isFirstPassSuccess": false
            }
            """.utf8)

        let outcome = try decoder.decode(TestOutcome.self, from: json)
        #expect(outcome.points == 3)
        #expect(outcome.longResult == "expected 42, got 0")
        #expect(outcome.isFirstPassSuccess == false)
    }

    @Test func testOutcomeRoundTrip() throws {
        let outcome = TestOutcome(
            testName: "testBaz",
            testClass: "PublicTests",
            tier: .secret,
            status: .timeout,
            shortResult: "timed out",
            longResult: nil,
            points: 2,
            executionTimeMs: 5000,
            memoryUsageBytes: 1024,
            attemptNumber: 3,
            isFirstPassSuccess: false
        )
        let data = try encoder.encode(outcome)
        let decoded = try decoder.decode(TestOutcome.self, from: data)
        #expect(decoded == outcome)
    }

    // MARK: - TestOutcomeCollection — custom decoder

    @Test func collectionTotalPointsFallsBackToTotalTests() throws {
        // Old JSON without totalPoints/earnedPoints/warnings/jobStartedAt
        let json = Data(
            """
            {
              "submissionID": "sub_001",
              "testSetupID": "setup_001",
              "attemptNumber": 1,
              "buildStatus": "passed",
              "outcomes": [],
              "totalTests": 5,
              "passCount": 3,
              "failCount": 2,
              "errorCount": 0,
              "timeoutCount": 0,
              "executionTimeMs": 500,
              "runnerVersion": "shell-runner/1.0",
              "timestamp": "1970-01-01T00:00:00Z"
            }
            """.utf8)

        let col = try decoder.decode(TestOutcomeCollection.self, from: json)
        #expect(col.totalPoints == 5)  // falls back to totalTests
        #expect(col.earnedPoints == 3)  // falls back to passCount
        #expect(col.warnings.isEmpty)  // defaults to empty
        #expect(col.jobStartedAt == nil)  // optional, absent
    }

    @Test func collectionExplicitPointsPreserved() throws {
        let outcome = TestOutcome(
            testName: "t1", testClass: nil, tier: .pub, status: .pass,
            shortResult: "passed", longResult: nil,
            points: 4, executionTimeMs: 10,
            memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: true
        )
        let col = TestOutcomeCollection(
            submissionID: "sub_002", testSetupID: "setup_002",
            attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [outcome],
            totalTests: 1, passCount: 1, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 10,
            totalPoints: 4, earnedPoints: 4,
            warnings: ["file renamed"],
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )

        let data = try encoder.encode(col)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        #expect(decoded.totalPoints == 4)
        #expect(decoded.earnedPoints == 4)
        #expect(decoded.warnings == ["file renamed"])
    }

    @Test func collectionRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_rt", testSetupID: "setup_rt",
            attemptNumber: 2, buildStatus: .failed,
            compilerOutput: "make: no rule for target",
            outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0,
            runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 1_000_000)
        )
        let data = try encoder.encode(col)
        let decoded = try decoder.decode(TestOutcomeCollection.self, from: data)
        #expect(decoded.submissionID == "sub_rt")
        #expect(decoded.buildStatus == .failed)
        #expect(decoded.compilerOutput == "make: no rule for target")
        #expect(decoded.outcomes.isEmpty)
    }

    // MARK: - Job

    @Test func jobRoundTrip() throws {
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 5 }
                """.utf8))

        let job = Job(
            submissionID: "sub_job",
            testSetupID: "setup_job",
            attemptNumber: 1,
            submissionURL: testURL("http://localhost:8080/worker/artifacts/sub_job"),
            testSetupURL: testURL("http://localhost:8080/api/v1/testsetups/setup_job/download"),
            manifest: manifest,
            submissionFilename: "warmup.py"
        )

        let data = try encoder.encode(job)
        let decoded = try decoder.decode(Job.self, from: data)
        #expect(decoded.submissionID == "sub_job")
        #expect(decoded.testSetupID == "setup_job")
        #expect(decoded.attemptNumber == 1)
        #expect(decoded.submissionFilename == "warmup.py")
        #expect(decoded.manifest.timeLimitSeconds == 5)
    }

    @Test func jobSubmissionFilenameNilRoundTrip() throws {
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 10 }
                """.utf8))

        let job = Job(
            submissionID: "sub_zip",
            testSetupID: "setup_zip",
            attemptNumber: 3,
            submissionURL: testURL("http://localhost/a"),
            testSetupURL: testURL("http://localhost/b"),
            manifest: manifest,
            submissionFilename: nil
        )
        let data = try encoder.encode(job)
        let decoded = try decoder.decode(Job.self, from: data)
        #expect(decoded.submissionFilename == nil)
    }

    @Test func runnerSanitizedStripsPatternFamilies() throws {
        let family = PatternFamily(
            id: "bmi",
            name: "BMI boundaries",
            kind: .boundaryEquality,
            functionName: "classify_bmi"
        )
        let manifest = TestProperties(
            schemaVersion: 1,
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_a.py")],
            timeLimitSeconds: 7,
            patternFamilies: [family]
        )

        let sanitized = manifest.runnerSanitized()
        #expect(sanitized.patternFamilies.isEmpty)
        #expect(sanitized.testSuites == manifest.testSuites)
        #expect(sanitized.timeLimitSeconds == 7)

        let roundTripped = try decoder.decode(
            TestProperties.self,
            from: try encoder.encode(sanitized)
        )
        #expect(roundTripped.patternFamilies.isEmpty)
    }

    @Test func runnerSanitizedStripsNotebookChecks() throws {
        let check = NotebookCheck(
            id: "df_shape",
            kind: .dataFrameShape,
            tier: .pub,
            points: 1,
            variable: "df",
            expectedRows: 250,
            expectedCols: 13
        )
        let manifest = TestProperties(
            schemaVersion: 1,
            testSuites: [
                TestSuiteEntry(
                    tier: .pub,
                    script: "publiccheck_df_shape.py",
                    generatedByCheck: "df_shape"
                )
            ],
            timeLimitSeconds: 7,
            notebookChecks: [check]
        )

        let sanitized = manifest.runnerSanitized()
        #expect(sanitized.notebookChecks.isEmpty)
        // testSuites entries — including the one with generatedByCheck —
        // are preserved.  Only the spec list is stripped.
        #expect(sanitized.testSuites.count == 1)
        #expect(sanitized.testSuites.first?.generatedByCheck == "df_shape")
    }

    // MARK: - TestItem / unified manifest list

    @Test func testItemFamilyRoundTripsThroughJSON() throws {
        let item = TestItem(
            family: PatternFamily(
                id: "bmi", name: "BMI boundaries", kind: .boundaryEquality,
                functionName: "classify_bmi"))
        let decoded = try decoder.decode(TestItem.self, from: try encoder.encode(item))
        #expect(decoded == item)
        #expect(decoded.type == .family)
        #expect(decoded.id == "bmi")
        #expect(decoded.family != nil)
        #expect(decoded.check == nil)
    }

    @Test func testItemCheckRoundTripsThroughJSON() throws {
        let item = TestItem(
            check: NotebookCheck(
                id: "df_shape", kind: .dataFrameShape, tier: .pub, points: 1,
                variable: "df", expectedRows: 250, expectedCols: 13))
        let decoded = try decoder.decode(TestItem.self, from: try encoder.encode(item))
        #expect(decoded == item)
        #expect(decoded.type == .check)
        #expect(decoded.id == "df_shape")
        #expect(decoded.check != nil)
        #expect(decoded.family == nil)
    }

    @Test func testPropertiesInitSynthesizesTestItemsFromLegacyArgs() throws {
        let fam = PatternFamily(
            id: "bmi", name: "BMI", kind: .boundaryEquality, functionName: "classify_bmi")
        let chk = NotebookCheck(id: "df_shape", kind: .dataFrameShape, variable: "df")
        let props = TestProperties(patternFamilies: [fam], notebookChecks: [chk])
        #expect(props.testItems.count == 2)
        // Families first, then checks (matches the documented synthesis order).
        #expect(props.testItems.first?.type == .family)
        #expect(props.testItems.last?.type == .check)
        #expect(props.patternFamilies == [fam])
        #expect(props.notebookChecks == [chk])
    }

    @Test func testPropertiesEncodeMirrorsLegacyKeysAndEmitsTestItems() throws {
        let props = TestProperties(
            patternFamilies: [
                PatternFamily(id: "f", name: "F", kind: .boundaryEquality, functionName: "g")
            ],
            notebookChecks: [NotebookCheck(id: "c", kind: .figureCount, minFigures: 1)])
        let obj =
            try JSONSerialization.jsonObject(with: try encoder.encode(props)) as? [String: Any]
        #expect(obj?["testItems"] != nil)
        #expect((obj?["patternFamilies"] as? [Any])?.count == 1)
        #expect((obj?["notebookChecks"] as? [Any])?.count == 1)
    }

    @Test func testPropertiesMigratesLegacyManifestOnRead() throws {
        // A pre-testItems manifest carries the separate arrays only.
        let legacy = """
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,\
            "patternFamilies":[{"id":"bmi","name":"BMI","kind":"boundary_equality",\
            "functionName":"classify_bmi"}],\
            "notebookChecks":[{"id":"df","kind":"data_frame_shape","variable":"df",\
            "expectedRows":1,"expectedCols":1}]}
            """
        let props = try decoder.decode(TestProperties.self, from: Data(legacy.utf8))
        #expect(props.testItems.count == 2)
        #expect(props.patternFamilies.first?.id == "bmi")
        #expect(props.notebookChecks.first?.id == "df")
        #expect(props.testItems.first?.type == .family)
        #expect(props.testItems.last?.type == .check)
    }

    @Test func testPropertiesPrefersTestItemsKeyWhenPresent() throws {
        let json = """
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10,\
            "testItems":[{"type":"family","spec":{"id":"only","name":"Only",\
            "kind":"boundary_equality","functionName":"f"}}]}
            """
        let props = try decoder.decode(TestProperties.self, from: Data(json.utf8))
        #expect(props.testItems.count == 1)
        #expect(props.patternFamilies.first?.id == "only")
        #expect(props.notebookChecks.isEmpty)
    }

    @Test func runnerSanitizedStripsTestItems() throws {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "a.py")],
            patternFamilies: [
                PatternFamily(id: "f", name: "F", kind: .boundaryEquality, functionName: "g")
            ],
            notebookChecks: [NotebookCheck(id: "c", kind: .figureCount, minFigures: 1)])
        let sanitized = props.runnerSanitized()
        #expect(sanitized.testItems.isEmpty)
        #expect(sanitized.patternFamilies.isEmpty)
        #expect(sanitized.notebookChecks.isEmpty)
        #expect(sanitized.testSuites == props.testSuites)
        // Round-trips clean through the runner's decoder too.
        let rt = try decoder.decode(
            TestProperties.self, from: try encoder.encode(sanitized))
        #expect(rt.testItems.isEmpty)
    }

    @Test func notebookCheckRoundTripsThroughJSON() throws {
        let check = NotebookCheck(
            id: "df_shape_full",
            name: "Full dataset shape",
            kind: .dataFrameShape,
            tier: .release,
            points: 2,
            dependsOn: ["public_load_df.py"],
            sectionID: "ex2",
            variable: "df",
            expectedRows: 250,
            expectedCols: 13
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
    }

    @Test func notebookCheckColumnsExactRoundTrip() throws {
        let check = NotebookCheck(
            id: "df_columns_full",
            kind: .dataFrameColumns,
            variable: "df",
            expectedColumns: ["caseid", "age", "sex", "height", "weight"],
            columnMatch: .exact
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.columnMatch == .exact)
    }

    @Test func notebookCheckColumnsSupersetRoundTrip() throws {
        let check = NotebookCheck(
            id: "df_required_cols",
            kind: .dataFrameColumns,
            variable: "df",
            expectedColumns: ["age", "sex"],
            columnMatch: .superset
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.columnMatch == .superset)
    }

    @Test func notebookCheckColumnsAbsentColumnMatchDecodesNil() throws {
        // When the manifest omits columnMatch, decode leaves it nil; the
        // renderer treats nil as .exact (the default).  Verify the field
        // is genuinely optional rather than coerced to a default at
        // decode time, so callers can distinguish "instructor didn't
        // pick" from "instructor picked exact".
        let json = """
            {
              "id": "x",
              "kind": "data_frame_columns",
              "tier": "public",
              "points": 1,
              "variable": "df",
              "expectedColumns": ["a", "b"]
            }
            """
        let decoded = try decoder.decode(NotebookCheck.self, from: Data(json.utf8))
        #expect(decoded.columnMatch == nil)
    }

    @Test func notebookCheckEqualityRoundTripsThroughJSON() throws {
        let check = NotebookCheck(
            id: "df_full_match",
            kind: .dataFrameEquality,
            tier: .release,
            points: 3,
            variable: "df_grouped",
            expectedCSV: "sex,age\nF,56.7\nM,59.4\n",
            checkDtype: true,
            checkLike: false,
            rtol: 1e-4,
            atol: 1e-7,
            ignoreIndex: true
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
    }

    @Test func notebookCheckSeriesRoundTripsThroughJSON() throws {
        let check = NotebookCheck(
            id: "scores_expected",
            kind: .seriesEquality,
            variable: "scores",
            expectedCSV: "score\n0.95\n0.88\n0.72\n",
            ignoreIndex: true
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
    }

    @Test func notebookCheckArrayRoundTripsThroughJSON() throws {
        let check = NotebookCheck(
            id: "predictions_close",
            kind: .numericArrayClose,
            variable: "y_pred",
            rtol: 1e-3,
            atol: 1e-6,
            expectedArray: [1.0, 2.5, 3.7, 4.9]
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
    }

    @Test func notebookCheckFigureCountRoundTrip() throws {
        let check = NotebookCheck(
            id: "ex4_two_charts",
            kind: .figureCount,
            tier: .release,
            points: 1,
            minFigures: 2
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.minFigures == 2)
    }

    @Test func notebookCheckCellContainsRoundTrip() throws {
        let check = NotebookCheck(
            id: "ex5_groupby",
            kind: .cellContains,
            tier: .release,
            points: 1,
            containsText: ".groupby(",
            regex: false,
            mustDifferFrom: "df.groupby(\"sex\")[\"age\"].mean()"
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
    }

    @Test func notebookCheckCellContainsRegexRoundTrip() throws {
        let check = NotebookCheck(
            id: "ex5_groupby_regex",
            kind: .cellContains,
            containsText: #"\.groupby\(['""].+['""]\)"#,
            regex: true
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.regex == true)
    }

    @Test func notebookCheckFunctionExistsRoundTrip() throws {
        let check = NotebookCheck(
            id: "fn_classify_bmi",
            kind: .functionExists,
            tier: .pub,
            points: 1,
            variable: "classify_bmi",
            expectedArity: 1
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.expectedArity == 1)
    }

    @Test func notebookCheckFunctionExistsNoArityRoundTrip() throws {
        let check = NotebookCheck(
            id: "fn_helper",
            kind: .functionExists,
            variable: "helper"
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.expectedArity == nil)
    }

    @Test func notebookCheckVariableExistsRoundTrip() throws {
        let check = NotebookCheck(
            id: "var_df",
            kind: .variableExists,
            tier: .pub,
            points: 1,
            variable: "df",
            expectedType: "DataFrame"
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.expectedType == "DataFrame")
    }

    @Test func notebookCheckVariableExistsNoTypeRoundTrip() throws {
        let check = NotebookCheck(
            id: "var_results",
            kind: .variableExists,
            variable: "results"
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.expectedType == nil)
    }

    @Test func patternFamilyReturnTypeCheckRoundTrip() throws {
        let check = PatternCase(
            key: "01",
            label: "returns a DataFrame",
            args: [.string("vitaldb.csv")],
            expected: .string("DataFrame")
        )
        let family = PatternFamily(
            id: "load_returns_df",
            name: "Load returns DataFrame",
            kind: .returnTypeCheck,
            functionName: "load_data",
            paramNames: ["filename"],
            cases: [check]
        )
        let data = try encoder.encode(family)
        let decoded = try decoder.decode(PatternFamily.self, from: data)
        #expect(decoded == family)
        #expect(decoded.kind == .returnTypeCheck)
    }

    @Test func patternFamilyExceptionExpectedRoundTrip() throws {
        let c = PatternCase(
            key: "01",
            label: "negative input raises ValueError",
            args: [.int(-1)],
            expected: .string("ValueError")
        )
        let family = PatternFamily(
            id: "neg_input_raises",
            name: "Negative input raises",
            kind: .exceptionExpected,
            functionName: "compute",
            paramNames: ["x"],
            cases: [c]
        )
        let data = try encoder.encode(family)
        let decoded = try decoder.decode(PatternFamily.self, from: data)
        #expect(decoded == family)
        #expect(decoded.kind == .exceptionExpected)
    }

    @Test func patternFamilyPerformanceThresholdRoundTrip() throws {
        // Use a fractional millisecond threshold so JSON round-trips it
        // as `.double` rather than collapsing to `.int`.  The renderer
        // accepts both shapes; the validator rejects only nil/zero/inf.
        let c = PatternCase(
            key: "01",
            label: "100k items finish under 200.5 ms",
            args: [.int(100_000)],
            expected: .double(200.5)
        )
        let family = PatternFamily(
            id: "perf_100k",
            name: "100k items perf",
            kind: .performanceThreshold,
            functionName: "process",
            paramNames: ["n"],
            cases: [c]
        )
        let data = try encoder.encode(family)
        let decoded = try decoder.decode(PatternFamily.self, from: data)
        #expect(decoded == family)
        #expect(decoded.kind == .performanceThreshold)
    }

    @Test func notebookCheckASTStructureRoundTrip() throws {
        let check = NotebookCheck(
            id: "no_for_loops",
            kind: .astStructure,
            requiredConstructs: ["list_comprehension", "!for_loop", "import:pandas"]
        )
        let data = try encoder.encode(check)
        let decoded = try decoder.decode(NotebookCheck.self, from: data)
        #expect(decoded == check)
        #expect(decoded.requiredConstructs?.count == 3)
    }

    @Test func notebookCheckEqualityLegacyManifestDecodesCleanly() throws {
        // Pre-equality manifests don't carry the new fields; decode must
        // leave them nil rather than throwing.
        let json = """
            {
              "id": "x",
              "kind": "data_frame_equality",
              "tier": "public",
              "points": 1,
              "variable": "df",
              "expectedCSV": "a,b\\n1,2\\n"
            }
            """
        let decoded = try decoder.decode(NotebookCheck.self, from: Data(json.utf8))
        #expect(decoded.checkDtype == nil)
        #expect(decoded.checkLike == nil)
        #expect(decoded.rtol == nil)
        #expect(decoded.atol == nil)
        #expect(decoded.ignoreIndex == nil)
    }

    @Test func testSuiteEntryIsGeneratedReportsBothGenerators() throws {
        let raw = TestSuiteEntry(tier: .pub, script: "manual.py")
        let family = TestSuiteEntry(
            tier: .pub, script: "publictest_bmi_01.py",
            generatedBy: "bmi"
        )
        let check = TestSuiteEntry(
            tier: .pub, script: "publiccheck_df_shape.py",
            generatedByCheck: "df_shape"
        )
        #expect(raw.isGenerated == false)
        #expect(family.isGenerated == true)
        #expect(check.isGenerated == true)
    }

    @Test func legacyManifestWithoutNotebookChecksDecodesAsEmpty() throws {
        // Pre-NotebookCheck manifests don't carry the notebookChecks field;
        // decoder must default to [].
        let manifest = try decoder.decode(
            TestProperties.self,
            from: Data(
                """
                { "schemaVersion": 1, "testSuites": [], "timeLimitSeconds": 10 }
                """.utf8))
        #expect(manifest.notebookChecks.isEmpty)
    }

    // MARK: - WorkerActivityPayload

    @Test func workerActivityPayloadRoundTrip() throws {
        let profile = RunnerCapabilityProfile(
            platform: "linux",
            architecture: "arm64",
            languageVersions: [LanguageVersion(language: "python", version: "3.11")],
            capabilities: [RunnerCapability(name: "jupyter")]
        )
        let payload = WorkerActivityPayload(
            workerID: "runner-01",
            hostname: "host.example.com",
            runnerVersion: "0.4.36",
            maxConcurrentJobs: 4,
            activeJobs: 2,
            profile: profile
        )

        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(WorkerActivityPayload.self, from: data)
        #expect(decoded.workerID == "runner-01")
        #expect(decoded.maxConcurrentJobs == 4)
        #expect(decoded.activeJobs == 2)
        #expect(decoded.profile?.platform == "linux")
        #expect(decoded.profile?.languageVersions.first?.language == "python")
    }

    @Test func workerActivityPayloadNilProfileRoundTrip() throws {
        let payload = WorkerActivityPayload(
            workerID: "runner-02", hostname: "h", runnerVersion: "0.4.0",
            maxConcurrentJobs: 1, activeJobs: 0, profile: nil
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(WorkerActivityPayload.self, from: data)
        #expect(decoded.profile == nil)
    }

    // MARK: - WorkerExecutionReport

    @Test func workerExecutionReportRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_r", testSetupID: "setup_r", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0, runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let diag = WorkerExecutionDiagnostics(
            runnerID: "runner-01",
            startedAt: Date(timeIntervalSince1970: 1000),
            finishedAt: Date(timeIntervalSince1970: 1010),
            finalStatus: "passed",
            timedOut: false,
            exitCode: 0,
            terminationReason: nil,
            peakRSSBytes: 4096,
            wallClockMs: 10_000,
            childProcessCount: 2,
            stdoutBytes: 128,
            stderrBytes: 0,
            stageTimings: WorkerExecutionStageTimings(
                workdirSetupMs: 15,
                submissionDownloadMs: 120,
                testSetupAcquireMs: 45,
                submissionPrepareMs: 210,
                testExecutionMs: 10_000
            ),
            freeDiskMBAtStart: 1024,
            freeDiskMBAtEnd: 960,
            workdirPeakBytes: 33_554_432
        )
        let report = WorkerExecutionReport(collection: col, diagnostics: diag)

        let data = try encoder.encode(report)
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: data)
        #expect(decoded.collection.submissionID == "sub_r")
        #expect(decoded.diagnostics?.runnerID == "runner-01")
        #expect(decoded.diagnostics?.timedOut == false)
        #expect(decoded.diagnostics?.peakRSSBytes == 4096)
        #expect(decoded.diagnostics?.terminationReason == nil)
        #expect(decoded.diagnostics?.stageTimings?.submissionDownloadMs == 120)
        #expect(decoded.diagnostics?.stageTimings?.testExecutionMs == 10_000)
        #expect(decoded.diagnostics?.freeDiskMBAtStart == 1024)
        #expect(decoded.diagnostics?.freeDiskMBAtEnd == 960)
        #expect(decoded.diagnostics?.workdirPeakBytes == 33_554_432)
    }

    @Test func workerExecutionDiagnosticsDecodesLegacyPayloadWithoutDiskFields() throws {
        // Older runners predate the disk-usage fields. Verify the synthesized
        // Codable decoder still accepts those payloads with the new optional
        // fields landing as nil.
        let legacyJSON = Data(
            """
            {
                "runnerID": "runner-legacy",
                "startedAt": "2024-01-01T00:00:00Z",
                "finishedAt": "2024-01-01T00:00:10Z",
                "finalStatus": "passed",
                "timedOut": false,
                "exitCode": 0,
                "terminationReason": null,
                "peakRSSBytes": null,
                "wallClockMs": 10000,
                "childProcessCount": null,
                "stdoutBytes": null,
                "stderrBytes": null,
                "stageTimings": null
            }
            """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkerExecutionDiagnostics.self, from: legacyJSON)
        #expect(decoded.runnerID == "runner-legacy")
        #expect(decoded.freeDiskMBAtStart == nil)
        #expect(decoded.freeDiskMBAtEnd == nil)
        #expect(decoded.workdirPeakBytes == nil)
    }

    @Test func workerExecutionReportNilDiagnosticsRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_nd", testSetupID: "setup_nd", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0, runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let report = WorkerExecutionReport(collection: col, diagnostics: nil)
        let data = try encoder.encode(report)
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: data)
        #expect(decoded.diagnostics == nil)
    }

    // MARK: - RunnerCapabilityProfile

    @Test func runnerCapabilityProfileRoundTrip() throws {
        let profile = RunnerCapabilityProfile(
            platform: "macos",
            architecture: "arm64",
            languageVersions: [
                LanguageVersion(language: "python", version: "3.12"),
                LanguageVersion(language: "r", version: "4.3.1"),
            ],
            capabilities: [RunnerCapability(name: "jupyter")]
        )
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(RunnerCapabilityProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.languageVersions.count == 2)
    }

    @Test func emptyRunnerCapabilityProfileRoundTrip() throws {
        let profile = RunnerCapabilityProfile(platform: "linux", architecture: "x86_64")
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(RunnerCapabilityProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.capabilities.isEmpty)
        #expect(decoded.languageVersions.isEmpty)
    }

    // MARK: - RunnerResult / RunnerOutcome

    @Test func runnerOutcomeRoundTrip() throws {
        let outcome = RunnerOutcome(
            testName: "testFoo", testClass: nil,
            tier: .pub, status: .pass,
            shortResult: "passed", longResult: nil,
            executionTimeMs: 30, memoryUsageBytes: nil
        )
        let data = try encoder.encode(outcome)
        let decoded = try decoder.decode(RunnerOutcome.self, from: data)
        #expect(decoded == outcome)
    }

    @Test func runnerResultRoundTrip() throws {
        let result = RunnerResult(
            runnerVersion: "shell-runner/1.0",
            buildStatus: .passed,
            compilerOutput: nil,
            executionTimeMs: 250,
            outcomes: [
                RunnerOutcome(
                    testName: "t1", testClass: nil, tier: .pub, status: .pass,
                    shortResult: "passed", longResult: nil,
                    executionTimeMs: 100, memoryUsageBytes: nil),
                RunnerOutcome(
                    testName: "t2", testClass: nil, tier: .release, status: .fail,
                    shortResult: "wrong", longResult: "expected 1, got 0",
                    executionTimeMs: 150, memoryUsageBytes: 512),
            ]
        )
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(RunnerResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.outcomes.count == 2)
        #expect(decoded.outcomes[1].longResult == "expected 1, got 0")
    }

    @Test func runnerResultFailedBuildRoundTrip() throws {
        let result = RunnerResult(
            runnerVersion: "shell-runner/1.0",
            buildStatus: .failed,
            compilerOutput: "make: no rule for target 'all'",
            executionTimeMs: 0,
            outcomes: []
        )
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(RunnerResult.self, from: data)
        #expect(decoded.buildStatus == .failed)
        #expect(decoded.compilerOutput == "make: no rule for target 'all'")
        #expect(decoded.outcomes.isEmpty)
    }

    // MARK: - CompatibilityResult.summaryDescription

    @Test func compatibilityResultSummaryCompatibleNoReasons() {
        let r = CompatibilityResult(isCompatible: true)
        #expect(r.summaryDescription == "compatible")
    }

    @Test func compatibilityResultSummaryIncompatibleNoReasons() {
        let r = CompatibilityResult(isCompatible: false)
        #expect(r.summaryDescription == "incompatible")
    }

    @Test func compatibilityResultSummaryJoinsReasons() {
        let r = CompatibilityResult(isCompatible: false, reasons: ["needs python 3.10", "needs jupyter"])
        #expect(r.summaryDescription == "needs python 3.10; needs jupyter")
    }
}
