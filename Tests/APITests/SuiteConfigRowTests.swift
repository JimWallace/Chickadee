// Tests/APITests/SuiteConfigRowTests.swift
//
// Suite config rows are decoded once into `SuiteConfigRow` (#2305). A config
// that is present but cannot be read is an error, not a silent fall back to the
// default suite, and one unresolved named row no longer drops the rows around it.

import Testing
import Vapor

@testable import APIServer

@Suite struct SuiteConfigRowTests {
    private let files = [
        ahMakeFile(named: "01_public.py", contents: "print('a')"),
        ahMakeFile(named: "02_secret.py", contents: "print('b')"),
    ]
    private let storedNames = [0: "01_public.py", 1: "02_secret.py"]

    @Test(arguments: ["not json", #"{"index":0}"#, #"[{"index":"zero"}]"#])
    func aConfigThatCannotBeReadIsRejected(_ config: String) {
        #expect(throws: SuiteConfigDecodingError.self) {
            _ = try buildSuiteEntries(
                suiteFiles: files, storedNameByIndex: storedNames, suiteConfigJSON: config)
        }
    }

    @Test(arguments: [nil, "", "  \n"])
    func noConfigStillUsesTheDefaultSuite(_ config: String?) throws {
        let entries = try buildSuiteEntries(
            suiteFiles: files, storedNameByIndex: storedNames, suiteConfigJSON: config)
        #expect(entries.map(\.script) == ["01_public.py", "02_secret.py"])
    }

    @Test func anUnresolvedNamedRowDoesNotDropTheOtherRows() async throws {
        let config = """
            [
              {"source":"existing","name":"missing.py","isTest":true,"tier":"public","order":1},
              {"index":1,"isTest":true,"tier":"secret","order":2,"points":4}
            ]
            """
        let (merged, mergedConfig) = await mergeExistingFilesIntoSuiteFiles(
            suiteFiles: files, suiteConfigJSON: config, draftZipPath: nil)
        let entries = try buildSuiteEntries(
            suiteFiles: merged, storedNameByIndex: storedNames, suiteConfigJSON: mergedConfig)

        #expect(entries.map(\.script) == ["02_secret.py"])
        #expect(entries.first?.tier == "secret")
        #expect(entries.first?.points == 4)
    }

    @Test func aNamedRowForAnUploadedFileTakesItsIndex() async throws {
        let config = #"[{"source":"existing","name":"02_secret.py","isTest":true,"tier":"release"}]"#
        let (_, mergedConfig) = await mergeExistingFilesIntoSuiteFiles(
            suiteFiles: files, suiteConfigJSON: config, draftZipPath: nil)
        let rows = try #require(try decodeSuiteConfigRows(mergedConfig))

        #expect(rows.count == 1)
        #expect(rows.first?.index == 1)
        #expect(rows.first?.name == nil)
        #expect(rows.first?.source == nil)
        #expect(rows.first?.tier == "release")
    }
}
