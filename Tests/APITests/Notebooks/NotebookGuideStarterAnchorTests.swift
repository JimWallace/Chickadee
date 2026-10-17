// Tests/APITests/Notebooks/NotebookGuideStarterAnchorTests.swift
//
// An assignment with no solution notebook yet: the guide reads the anchors
// from the student's starter, so each task still has its section anchor and
// its starter source, and the editor can tell "still the starter code".

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct NotebookGuideStarterAnchorTests {

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"worker","language":"python","requiredFiles":[],\
        "sections":[{"id":"s1","name":"Task 1: Count"}],\
        "testSuites":[{"tier":"public","script":"test_count.py","sectionID":"s1"}],"timeLimitSeconds":10}
        """

    private let starter = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
        {"cell_type":"markdown","id":"h1","metadata":{},"source":["## Task 1: Count\\n"]},\
        {"cell_type":"code","id":"c1","metadata":{},"outputs":[],"execution_count":null,\
        "source":["def count_to(n):\\n","    return []\\n"]}]}
        """

    @Test func withNoSolutionTheStarterGivesTheSectionAnchor() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await wrEnrollUser(try await wrStudentUser(on: app), on: app)
            let setup = try await wrInsertSetup(id: "setup_nosol", manifest: manifest, on: app)
            let notebookPath = app.testSetupsDirectory + "setup_nosol.ipynb"
            try starter.write(to: URL(fileURLWithPath: notebookPath), atomically: true, encoding: .utf8)
            setup.notebookPath = notebookPath
            try await setup.save(on: app.db)
            try await wrInsertAssignment(testSetupID: "setup_nosol", title: "No Solution Lab", isOpen: true, on: app)

            var body = ""
            try await app.asyncTest(
                .GET, "/testsetups/setup_nosol/notebook-guide.json",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    body = res.body.string
                })
            let guide = try JSONDecoder().decode(NotebookGuide.self, from: Data(body.utf8))
            let task = try #require(guide.tasks.first)
            #expect(task.anchors.map(\.kind) == ["section"])
            #expect(task.anchors.map(\.name) == ["Task 1: Count"])
            #expect(guide.starterSources["section:Task 1: Count"] == "def count_to(n):\n    return []")
        }
    }
}
