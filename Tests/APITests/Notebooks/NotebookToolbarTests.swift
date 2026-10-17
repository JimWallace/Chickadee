// Tests/APITests/Notebooks/NotebookToolbarTests.swift
//
// The notebook editor's one toolbar (notebook views NB2, design frame 18a)
// and the definition patterns the page passes to the editor extension.

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookToolbarTests {

    private func render(
        _ options: ElementaryPageFixtures.NotebookBodyOptions,
        title: String? = "Lab 4: Loops", due: String? = "Thu Oct 23, 23:59", csrf: String? = "tok",
        patterns: [String] = []
    ) -> String {
        var body = ElementaryPageFixtures.notebookBody(options)
        body.assignmentTitle = title
        body.dueLabel = due
        body.csrfToken = csrf
        body.definitionPatterns = patterns
        return body.render()
    }

    @Test func theEditButtonsNameTheConfirmedCommands() {
        let html = render(.init(showSubmit: true))
        #expect(html.contains(#"role="toolbar" aria-label="Notebook""#))
        #expect(html.contains(#"data-nb-commands="notebook:run-cell-and-select-next""#))
        #expect(html.contains(#"data-nb-commands="notebook:run-all-cells""#))
        #expect(html.contains(#"data-nb-commands="notebook:insert-cell-below notebook:change-cell-to-code""#))
        #expect(html.contains(#"data-nb-commands="notebook:insert-cell-below notebook:change-cell-to-markdown""#))
        #expect(html.contains(#"data-nb-commands="notebook:restart-kernel""#))
        #expect(html.contains(#"data-nb-commands="notebook:clear-all-cell-outputs""#))
        #expect(!html.contains("kernel:restart\""))
    }

    @Test func theStudentToolbarHasTheTitleTheMenuAndSubmitLast() throws {
        let html = render(.init(showSubmit: true))
        #expect(html.contains("<strong>Lab 4: Loops</strong>"))
        #expect(html.contains("Due Thu Oct 23, 23:59"))
        #expect(html.contains(#"data-nb-upload="nb-menu-upload-file""#))
        #expect(html.contains(#"action="/testsetups/setup-1/reset-notebook""#))
        #expect(html.contains("Reset to starter"))
        let chip = try #require(html.range(of: "id=\"nb-kernel-chip\""))
        let menu = try #require(html.range(of: "More actions for the notebook"))
        let submit = try #require(html.range(of: "id=\"nb-submit\""))
        #expect(chip.lowerBound < menu.lowerBound)
        #expect(menu.lowerBound < submit.lowerBound)
    }

    @Test func aReadOnlyNotebookHasNoEditButtons() {
        let html = render(.init(isClosed: true, isReadOnly: true))
        #expect(!html.contains("notebook:run-all-cells"))
        #expect(!html.contains("notebook:restart-kernel"))
        #expect(!html.contains("notebook:clear-all-cell-outputs"))
    }

    @Test func theWorkbenchPaneHasNoTitleAndNoReset() {
        let html = render(.init(showSubmit: true, embedded: true))
        #expect(!html.contains("Lab 4: Loops"))
        #expect(!html.contains("reset-notebook"))
    }

    @Test func noTokenLeavesResetOut() {
        let html = render(.init(showSubmit: true), csrf: nil)
        #expect(!html.contains("reset-notebook"))
    }

    @Test func theFrameCarriesTheDefinitionPatternsAsJSON() {
        let html = render(.init(showSubmit: true), patterns: [#"^def\s+(x)"#])
        #expect(html.contains(#"data-definition-patterns="[&quot;^def\\s+(x)&quot;]""#))
    }

    // MARK: - The patterns

    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave])
    func eachKernelLanguageHasFunctionAndVariablePatternsThatCompile(language: AssignmentLanguage) throws {
        let patterns = language.descriptor.definitionLinePatterns
        #expect(patterns.count >= 2)
        for pattern in patterns {
            _ = try Regex(pattern)
        }
    }

    @Test(arguments: [AssignmentLanguage.cpp, .racket, .java])
    func anUploadOnlyLanguageHasNoPatterns(language: AssignmentLanguage) {
        #expect(language.descriptor.definitionLinePatterns.isEmpty)
    }

    @Test func thePythonPatternsReadADefAndAnAssignment() throws {
        let patterns = try AssignmentLanguage.python.descriptor.definitionLinePatterns.map { try Regex($0) }
        func name(_ line: String) -> String? {
            for pattern in patterns {
                if let match = line.firstMatch(of: pattern), let name = match.output[1].substring {
                    return String(name)
                }
            }
            return nil
        }
        #expect(name("def average_heart_rate(readings):") == "average_heart_rate")
        #expect(name("GOAL = 8000") == "GOAL")
        #expect(name("if GOAL == 8000:") == nil)
    }

    @Test func theRouteFactReadsTheDeclaredLanguage() {
        let manifest = #"{"schemaVersion":1,"language":"r","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        #expect(
            NotebookBootFacts.definitionPatterns(manifestJSON: manifest)
                == AssignmentLanguage.r.descriptor.definitionLinePatterns)
        #expect(NotebookBootFacts.definitionPatterns(manifestJSON: "nope").isEmpty)
    }
}
