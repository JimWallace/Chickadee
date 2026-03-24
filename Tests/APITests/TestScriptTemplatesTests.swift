// Tests/CoreTests/TestScriptTemplatesTests.swift
//
// Unit tests for TestScriptTemplates.
// These tests import the server module because templates live in APIServer, not Core.

import XCTest
@testable import chickadee_server

final class TestScriptTemplatesTests: XCTestCase {

    // MARK: - Python templates

    func testExistsTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exists, functionName: "myFunc", paramNames: ["x", "y"])
        XCTAssertTrue(s.contains("myFunc"))
        XCTAssertTrue(s.contains("require_function"))
        XCTAssertTrue(s.contains("passed"))
    }

    func testExistsTemplate_numArgsIncluded_whenParamsPresent() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("num_args=2"))
    }

    func testExistsTemplate_noNumArgs_whenNoParams() {
        let s = pythonTestScript(type: .exists, functionName: "f", paramNames: [])
        XCTAssertFalse(s.contains("num_args"))
    }

    func testCorrectnessTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .correctness, functionName: "add", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("add"))
        XCTAssertTrue(s.contains("passed"))
        XCTAssertTrue(s.contains("failed"))
    }

    func testCorrectnessTemplate_nonEmpty() {
        let s = pythonTestScript(type: .correctness, functionName: "f")
        XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testCornerCasesTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .cornerCases, functionName: "check", paramNames: ["n"])
        XCTAssertTrue(s.contains("check"))
        XCTAssertTrue(s.contains("corner_cases"))
    }

    func testExceptionTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .exception, functionName: "divide", paramNames: ["a", "b"])
        XCTAssertTrue(s.contains("divide"))
        XCTAssertTrue(s.contains("ValueError"))
    }

    func testTypeCheckTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .typeCheck, functionName: "items", paramNames: [])
        XCTAssertTrue(s.contains("items"))
        XCTAssertTrue(s.contains("isinstance"))
    }

    func testPerformanceTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .performance, functionName: "sort_it", paramNames: ["lst"])
        XCTAssertTrue(s.contains("sort_it"))
        XCTAssertTrue(s.contains("time_limit_ms"))
    }

    func testDifferentialTemplate_containsFunctionName() {
        let s = pythonTestScript(type: .differential, functionName: "square", paramNames: ["n"])
        XCTAssertTrue(s.contains("square"))
        XCTAssertTrue(s.contains("_reference_square"))
    }

    func testAllPythonTemplateTypes_nonEmpty() {
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "f", paramNames: ["x"])
            XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Template \(type.rawValue) should not be empty")
        }
    }

    func testAllPythonTemplateTypes_containFunctionName() {
        for type in PythonTestTemplateType.allCases {
            let s = pythonTestScript(type: type, functionName: "mySpecialFunc", paramNames: ["a"])
            XCTAssertTrue(s.contains("mySpecialFunc"),
                          "Template \(type.rawValue) should contain the function name")
        }
    }

    func testDefaultFunctionName_usedWhenNotSpecified() {
        let s = pythonTestScript(type: .exists)
        XCTAssertTrue(s.contains("my_function"))
    }

    // MARK: - Shell templates

    func testShellAlwaysPass() {
        let s = shellTestScript(type: .alwaysPass)
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("#!/bin/sh"))
    }

    func testShellFileExists() {
        let s = shellTestScript(type: .fileExists)
        XCTAssertTrue(s.contains("#!/bin/sh"))
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("exit 1"))
        XCTAssertTrue(s.contains("-f"))
    }

    func testShellCommandOutput() {
        let s = shellTestScript(type: .commandOutput)
        XCTAssertTrue(s.contains("#!/bin/sh"))
        XCTAssertTrue(s.contains("exit 0"))
        XCTAssertTrue(s.contains("exit 1"))
        XCTAssertTrue(s.contains("EXPECTED"))
        XCTAssertTrue(s.contains("ACTUAL"))
    }

    func testAllShellTemplateTypes_nonEmpty() {
        for type in ShellTestTemplateType.allCases {
            let s = shellTestScript(type: type)
            XCTAssertFalse(s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Shell template \(type.rawValue) should not be empty")
        }
    }

    // MARK: - allTemplateInfos

    func testAllTemplateInfos_countMatchesTypes() {
        let infos = allTemplateInfos(functionName: "foo", paramNames: ["x"])
        let expectedCount = PythonTestTemplateType.allCases.count + ShellTestTemplateType.allCases.count
        XCTAssertEqual(infos.count, expectedCount)
    }

    func testAllTemplateInfos_eachHasContent() {
        let infos = allTemplateInfos(functionName: "bar", paramNames: [])
        for info in infos {
            XCTAssertFalse(info.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "Template \(info.id) content should not be empty")
        }
    }

    func testAllTemplateInfos_pythonContainFunctionName() {
        let infos = allTemplateInfos(functionName: "special_fn", paramNames: ["x"])
        let pythonInfos = infos.filter { $0.language == "python" }
        for info in pythonInfos {
            XCTAssertTrue(info.content.contains("special_fn"),
                          "Python template \(info.id) should contain function name")
        }
    }
}
