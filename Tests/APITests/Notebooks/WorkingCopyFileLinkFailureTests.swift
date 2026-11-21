// Tests/APITests/Notebooks/WorkingCopyFileLinkFailureTests.swift
//
// The failure paths of the two passes that fill a student's working folder
// on each notebook visit, and of the per-student evaluator. The coverage
// report showed no test for any of them. Each one must leave the notebook
// open and say in the log what went wrong:
//
// - a support file that cannot be linked is logged by name, and the other
//   support files are still linked;
// - a shared dataset that cannot be linked fails the pass, which is logged,
//   and the next visit links it;
// - an expression that the evaluator cannot evaluate leaves its placeholder,
//   keeps the literal values, and is logged.

import ChickadeeTestSupport
import Fluent
import Foundation
import Logging
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct WorkingCopyFileLinkFailureTests {

    private func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// `data/a.csv` cannot be linked when the student's folder holds a file
    /// named `data`. That one link fails and is logged; `notes.txt` beside it
    /// is still linked.
    @Test func aSupportFileThatCannotBeLinkedIsLoggedAndTheOthersAreLinked() async throws {
        try await withTestApp(prefix: "chickadee-wc-supportfail") { app in
            let course = try await makeTestCourse(on: app, code: "WCL101")
            let setupID = "setup_wc_supportfail"
            let zipPath = app.testSetupsDirectory + "\(setupID).zip"
            try await writeZipFixture(at: zipPath, entries: [("notes.txt", "n\n"), ("data/a.csv", "x\n1\n")])
            let setup = APITestSetup(
                id: setupID,
                manifest: #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#,
                zipPath: zipPath, courseID: try course.requireID())
            try await setup.save(on: app.db)

            let fm = FileManager.default
            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try fm.createDirectory(atPath: sharedDir + "data", withIntermediateDirectories: true)
            try "n\n".write(toFile: sharedDir + "notes.txt", atomically: true, encoding: .utf8)
            try "x\n1\n".write(toFile: sharedDir + "data/a.csv", atomically: true, encoding: .utf8)

            let studentDir = app.testSetupsDirectory + "student-wc-supportfail"
            try fm.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
            try "in the way".write(toFile: studentDir + "/data", atomically: true, encoding: .utf8)

            let capture = CapturedLog(minimumLevel: .warning)
            app.logger = capture.logger
            await createSupportFileSymlinks(setup: setup, studentDir: studentDir, application: app)

            #expect(linkTarget(studentDir + "/notes.txt") == sharedDir + "notes.txt")
            #expect(
                capture.messages(containing: "support_file_link_failed setup=\(setupID) file=data/a.csv").count == 1)
            #expect(try String(contentsOfFile: studentDir + "/data", encoding: .utf8) == "in the way")
        }
    }

    /// A shared dataset whose link cannot be made fails the pass: the failure
    /// is logged. Once the cause is gone, the
    /// next visit links the file.
    @Test func aSharedDatasetThatCannotBeLinkedIsLoggedAndLinkedOnTheNextVisit() async throws {
        try await withTestApp(prefix: "chickadee-wc-dslinkfail") { app in
            let course = try await makeTestCourse(on: app, code: "WCD101")
            let courseID = try course.requireID()
            let user = try await makeTestUser(on: app, username: "wc_dslinkfail_student")
            let userID = try user.requireID()

            let setupID = "setup_wc_dslinkfail"
            let setup = APITestSetup(
                id: setupID,
                manifest: """
                    {"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10,\
                    "datasets":[{"file":"whole.csv"}]}
                    """,
                zipPath: app.testSetupsDirectory + "\(setupID).zip", courseID: courseID)
            try await setup.save(on: app.db)
            try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)

            let fm = FileManager.default
            let sharedDir = app.testSetupsDirectory + "shared/\(setupID)/"
            try fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true)
            try "id\n1\n".write(toFile: sharedDir + "whole.csv", atomically: true, encoding: .utf8)

            // A regular file where the student's folder belongs: no link can
            // be made inside it.
            let studentDir = app.testSetupsDirectory + "student-wc-dslinkfail"
            try "in the way".write(toFile: studentDir, atomically: true, encoding: .utf8)

            let capture = CapturedLog(minimumLevel: .warning)
            app.logger = capture.logger
            func visit() async {
                await writeDatasetFiles(
                    setup: setup, userID: userID, studentDir: studentDir, on: app.db, application: app)
            }

            await visit()
            #expect(capture.messages(containing: "Dataset materialization failed for setup \(setupID)").count == 1)

            try fm.removeItem(atPath: studentDir)
            try fm.createDirectory(atPath: studentDir, withIntermediateDirectories: true)
            await visit()
            #expect(linkTarget(studentDir + "/whole.csv") == sharedDir + "whole.csv")
            #expect(capture.messages(containing: "Dataset materialization failed").count == 1)
        }
    }

    /// An expression that raises gives no value. The literal values are still
    /// substituted, the expression's placeholder stays, and the failure is
    /// logged.
    @Test(.requiresPython3) func anExpressionThatFailsLeavesItsPlaceholderAndIsLogged() async throws {
        try await withTestApp(prefix: "chickadee-wc-evalfail") { app in
            let course = try await makeTestCourse(on: app, code: "WCE101")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(
                on: app, id: "setup_wc_evalfail", courseID: courseID,
                manifest: """
                    {"schemaVersion":1,"language":"python","languageDeclared":true,"requiredFiles":[],\
                    "testSuites":[],"timeLimitSeconds":10,"globalVariables":[{"name":"cap","value":5}],\
                    "globalExpressions":[{"name":"broken","expression":"1 / 0"}]}
                    """,
                withZip: false)
            try await makeTestAssignment(on: app, testSetupID: "setup_wc_evalfail", courseID: courseID)
            let user = try await makeTestUser(on: app, username: "wc_evalfail_student")
            let capture = CapturedLog(minimumLevel: .warning)
            let seed = Data(
                #"""
                {"cells":[{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],\#
                "source":["cap = {{cap}}\nbroken = {{broken}}"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
                """#.utf8)

            let result = try await workingCopySeedData(
                WorkingCopySeedSource(
                    setupID: "setup_wc_evalfail", userID: try user.requireID(), setup: setup, defaultData: seed,
                    viewMode: .personalized),
                on: app.db, application: app, logger: capture.logger)

            let text = try #require(String(data: result, encoding: .utf8))
            #expect(text.contains("cap = 5"))
            #expect(text.contains("broken = {{broken}}"))
            #expect(
                capture.messages(containing: "Personalization evaluator failed for setup setup_wc_evalfail").count == 1)
        }
    }
}
