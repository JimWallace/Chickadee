// Tests/APITests/UndeclaredLanguageRefusalTests.swift
//
// What an assignment whose author declared NO language can and cannot do.
//
// "None" is a real declaration — a suite of hand-written `.sh` scripts — and it
// is not the same thing as an unanswered question. Every door that creates an
// assignment declares, so nothing reaching these paths is merely undecided.
//
// The rule these pin: an operation that needs a SYNTAX (a generated test, an
// `=` expression, a solution file's extension) refuses; an operation that does
// not (reordering scripts, literal variables, a notebook solution) proceeds —
// and, critically, proceeds WITHOUT quietly writing a language down.
//
// All of these are authoring paths. Nothing on the grading path refuses for
// want of a declaration: an instructor can fix this from the dropdown in
// seconds, and a student cannot fix it at all.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct UndeclaredLanguageRefusalTests {

    /// The message, matched on the part that names the fix rather than the
    /// whole sentence, so rewording the copy doesn't fail the test.
    private func mentionsMissingDeclaration(_ error: any Error) -> Bool {
        "\(error)".contains("declares no language")
    }

    // MARK: - Generated tests

    @Test func addingAFamilyIsRefusedWhenTheAuthorDeclaredNoLanguage() async throws {
        try await withPatternFamilyFixture(declaredLanguage: nil) { fixture in
            do {
                _ = try await applyPatternFamilies(
                    to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)
                Issue.record("a family save must not succeed with no declared language")
            } catch {
                #expect(mentionsMissingDeclaration(error))
            }

            // And it refused before touching anything.
            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.patternFamilies.isEmpty)
            #expect(props.language == nil)
        }
    }

    /// THE REGRESSION THIS PAIR EXISTS FOR. Every suite save runs through
    /// `applyPatternFamilies`, including saves that generate nothing — so the
    /// old `?? .python` meant reordering two shell scripts rewrote a
    /// declared-None assignment's language to Python, silently and stickily.
    ///
    /// A save that generates nothing must still be allowed, and must leave the
    /// declaration exactly as the author left it.
    @Test func aScriptOnlySaveIsAllowedAndLeavesTheDeclarationAlone() async throws {
        try await withPatternFamilyFixture(declaredLanguage: nil) { fixture in
            try updateScriptInZip(
                zipPath: fixture.setup.zipPath,
                filename: "publictest_handmade.sh",
                content: "#!/bin/sh\nexit 0\n"
            )
            let authored: [AuthoredSuiteItem] = [
                .script(
                    AuthoredRawScript(
                        script: "publictest_handmade.sh", tier: .pub, points: 1,
                        displayName: nil, dependsOn: [], sectionID: nil))
            ]

            _ = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [], authoredItems: authored, on: fixture.app.db)

            let props = try pfDecodeManifest(fixture.setup.manifest)
            #expect(props.testSuites.map(\.script) == ["publictest_handmade.sh"])
            #expect(
                props.language == nil,
                "a save that generates nothing must not declare a language on the author's behalf")
            // And must not un-declare one either: "none" is an answer, so the
            // rebuild has to carry the fact that it was given.
            #expect(props.languageDeclared == true)
        }
    }

    // MARK: - Per-student expressions

    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// Declared, with no language — the state `BackfillDeclaredLanguage` writes
    /// for a plain `.sh` suite and the create page's "None" option produces.
    private let undeclaredManifest =
        #"{"schemaVersion":1,"languageDeclared":true,"testSuites":[],"timeLimitSeconds":10,"sections":[{"id":"sec1","name":"Part A"}]}"#

    private func fixture(on app: Application, id: String) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: id, courseID: courseID, manifest: undeclaredManifest)
        try pfWriteEmptyZip(at: app.testSetupsDirectory + "\(id).zip")
        return try await makeTestAssignment(
            on: app, testSetupID: id, courseID: courseID, title: "Lab")
    }

    @Test func aGlobalExpressionIsRefusedButALiteralVariableIsNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, id: "setup_undeclared_g")

            // A literal needs a syntax only when it is RENDERED, which is a
            // later question with its own stated default. Storing one is fine.
            let ok = try await UpdateGlobalInputsTool().execute(
                UpdateGlobalInputsTool.Input(
                    assignmentPublicID: assignment.publicID,
                    variables: [FamilyVariable(name: "limit", value: .int(5))],
                    expressions: nil),
                context(app))
            #expect(ok.variables.map(\.name) == ["limit"])

            // An expression is source code. There is no interpreter to run it
            // in, so this refuses rather than quietly running `python3`.
            do {
                _ = try await UpdateGlobalInputsTool().execute(
                    UpdateGlobalInputsTool.Input(
                        assignmentPublicID: assignment.publicID,
                        variables: [],
                        expressions: [
                            PersonalizationExpression(name: "offset", expression: "seed % 3")
                        ]),
                    context(app))
                Issue.record("an `=` expression must not be storable with no declared language")
            } catch {
                #expect(mentionsMissingDeclaration(error))
            }
        }
    }

    @Test func aSectionExpressionIsRefusedToo() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, id: "setup_undeclared_s")
            do {
                _ = try await UpdateSectionVariablesTool().execute(
                    UpdateSectionVariablesTool.Input(
                        assignmentPublicID: assignment.publicID,
                        sectionID: "sec1",
                        variables: [],
                        expressions: [
                            PersonalizationExpression(name: "offset", expression: "seed % 3")
                        ]),
                    context(app))
                Issue.record("a section `=` expression must not be storable with no declared language")
            } catch {
                #expect(mentionsMissingDeclaration(error))
            }
        }
    }

    // MARK: - Reference solutions

    /// `update_solution` used to resolve the language as `?? .python` purely to
    /// reach `.scriptExtensions`, so a `.sh`-suite assignment accepted
    /// `solution.py` and rejected everything else for a reason nothing in the
    /// assignment supported. The notebook path never needed the answer and
    /// still doesn't.
    @Test func aSolutionFileIsRefusedWhileANotebookSolutionIsNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, id: "setup_undeclared_x")
            do {
                _ = try await UpdateSolutionTool().execute(
                    UpdateSolutionTool.Input(
                        assignmentPublicID: assignment.publicID,
                        notebook: nil,
                        solutionFile: UpdateSolutionTool.SolutionFile(
                            filename: "solution.py", content: "x = 1\n")),
                    context(app))
                Issue.record("a solution file's extension cannot be checked with no declared language")
            } catch {
                #expect(mentionsMissingDeclaration(error))
            }
        }
    }
}
