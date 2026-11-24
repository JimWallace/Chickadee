// Tests/CoreTests/Manifest/TestItemCodableTests.swift
//
// `TestItem`, the unified manifest list of families and checks: its JSON
// round-trips, the legacy-manifest migration, and each `NotebookCheck` kind.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct TestItemCodableTests: ISO8601CodingSuite {

    @Test func testItemFamilyRoundTripsThroughJSON() throws {
        let item = TestItem.family(
            PatternFamily(
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
        let item = TestItem.check(
            NotebookCheck(
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
        let props = TestProperties(language: nil, patternFamilies: [fam], notebookChecks: [chk])
        #expect(props.testItems.count == 2)
        // Families first, then checks (matches the documented synthesis order).
        #expect(props.testItems.first?.type == .family)
        #expect(props.testItems.last?.type == .check)
        #expect(props.patternFamilies == [fam])
        #expect(props.notebookChecks == [chk])
    }

    /// The legacy arrays are read (next test) but no longer written: the
    /// write-side mirror was removed at 0.6.0.
    @Test func testPropertiesEncodeEmitsTestItemsWithoutTheLegacyKeys() throws {
        let props = TestProperties(
            language: nil,
            patternFamilies: [
                PatternFamily(id: "f", name: "F", kind: .boundaryEquality, functionName: "g")
            ],
            notebookChecks: [NotebookCheck(id: "c", kind: .figureCount, minFigures: 1)])
        let obj =
            try JSONSerialization.jsonObject(with: try encoder.encode(props)) as? [String: Any]
        #expect((obj?["testItems"] as? [Any])?.count == 2)
        #expect(obj?["patternFamilies"] == nil)
        #expect(obj?["notebookChecks"] == nil)
        // And the bytes still decode to the same families and checks.
        let decoded = try decoder.decode(TestProperties.self, from: try encoder.encode(props))
        #expect(decoded.patternFamilies == props.patternFamilies)
        #expect(decoded.notebookChecks == props.notebookChecks)
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
            language: nil,
            patternFamilies: [
                PatternFamily(id: "f", name: "F", kind: .boundaryEquality, functionName: "g")
            ],
            notebookChecks: [NotebookCheck(id: "c", kind: .figureCount, minFigures: 1)])
        let sanitized = props.runnerManifest().testProperties
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
}
