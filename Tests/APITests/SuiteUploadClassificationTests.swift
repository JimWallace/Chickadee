// Tests/APITests/SuiteUploadClassificationTests.swift
//
// Which uploaded suite files are tests and which are support files (#1960).
// One rule serves both upload doors: the create form's multipart upload and
// the suite table's JSON upload.

import Core
import Testing

@testable import APIServer

@Suite struct SuiteUploadClassificationTests {

    /// One file per interpreter the runner dispatches by extension.
    @Test(arguments: [
        "t.sh", "t.bash", "t.zsh", "t.py", "t.rb", "t.pl", "t.js", "t.php",
        "t.R", "t.lua", "t.m", "t.rkt", "T.java",
    ])
    func aFileTheRunnerCanDispatchIsATest(name: String) {
        #expect(isLikelyTestSuiteScript(name: name, leadingText: ""))
    }

    /// A file the runner cannot run is support, whatever its text says.
    /// C++ headers and sources are support: C++ tests are `.sh` wrappers.
    @Test(arguments: [
        "data.csv", "README.md", "solution.ipynb", "helper.cpp", "ck.h", "ck.hpp",
        "image.png", "archive.tar.gz",
    ])
    func aFileTheRunnerCannotDispatchIsSupport(name: String) {
        #expect(!isLikelyTestSuiteScript(name: name, leadingText: "#!/bin/sh\nimport os\n"))
    }

    /// Every language's generated test is a test, so a new language cannot
    /// generate scripts its own upload files as support.
    @Test func everyLanguagesGeneratedScriptIsATest() {
        for language in AssignmentLanguage.allCases {
            let name = "publictest_case.\(language.generatedScriptExtension)"
            #expect(isLikelyTestSuiteScript(name: name, leadingText: ""), "\(language)")
        }
    }

    @Test func anExtensionlessFileIsATestOnlyWithAKnownShebang() {
        #expect(isLikelyTestSuiteScript(name: "check", leadingText: "#!/bin/sh\necho ok\n"))
        #expect(isLikelyTestSuiteScript(name: "check", leadingText: "#!/usr/bin/env bash\n"))
        #expect(isLikelyTestSuiteScript(name: "check", leadingText: "#!/usr/bin/env python3\n"))
        #expect(isLikelyTestSuiteScript(name: "check", leadingText: "#!/usr/bin/env lua\n"))
        #expect(!isLikelyTestSuiteScript(name: "notes", leadingText: "echo no shebang\n"))
        #expect(!isLikelyTestSuiteScript(name: "notes", leadingText: ""))
    }
}
