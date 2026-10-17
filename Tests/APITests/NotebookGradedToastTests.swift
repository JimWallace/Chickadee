// Tests/APITests/NotebookGradedToastTests.swift
//
// The graded toast (notebook views NB5, design frame 18f): the notebook body
// renders it hidden for a student's own notebook, and notebook-graded.js fills
// it in. It is a status region with See results and Keep editing.

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookGradedToastTests {

    private func bird() throws -> AvatarPresentation {
        let json = try #require(AvatarStore.encode(AvatarSpec.drawn(fromSeed: 11)))
        return try #require(NotebookBootFacts.bird(avatarSpecJSON: json, isStaff: false))
    }

    private func toast(_ html: String) -> String? {
        guard let start = html.range(of: #"<div id="nb-graded""#) else { return nil }
        guard let end = html.range(of: "Keep editing</button>", range: start.upperBound..<html.endIndex) else {
            return nil
        }
        return String(html[start.lowerBound..<end.upperBound])
    }

    @Test func aStudentsNotebookHasTheHiddenToast() throws {
        var body = ElementaryPageFixtures.notebookBody(.init(showSubmit: true))
        body.bootBird = try bird()
        let html = try #require(toast(body.render()))
        #expect(html.contains(#"class="nb-graded" role="status" hidden"#))
        #expect(html.contains(#"class="nb-graded-bird" aria-hidden="true""#))
        #expect(html.components(separatedBy: #"class="nb-graded-star""#).count - 1 == 3)
        #expect(html.contains("js-nb-graded-caption"))
        #expect(html.contains("js-nb-graded-grade"))
        #expect(html.contains("js-nb-graded-summary"))
        #expect(html.contains(#"id="nb-graded-results""#))
        #expect(html.contains("See results"))
        #expect(html.contains(#"<button class="btn" type="button" id="nb-graded-close">Keep editing</button>"#))
    }

    @Test func withNoBirdTheToastHasNoBird() throws {
        let body = ElementaryPageFixtures.notebookBody(.init(showSubmit: true))
        let html = try #require(toast(body.render()))
        #expect(!html.contains("nb-graded-bird"))
    }

    @Test(arguments: [
        ElementaryPageFixtures.NotebookBodyOptions(showSubmit: false),
        ElementaryPageFixtures.NotebookBodyOptions(showSubmit: true, embedded: true),
    ])
    func onlyAStudentsOwnNotebookHasTheToast(options: ElementaryPageFixtures.NotebookBodyOptions) {
        let html = ElementaryPageFixtures.notebookBody(options).render()
        #expect(!html.contains("nb-graded"))
    }

    @Test func thePageLoadsTheToastScriptAfterTheGuide() throws {
        let html = ElementaryPageFixtures.notebookBody(.init(showSubmit: true)).render()
        let guide = try #require(html.range(of: "/notebook-guide.js"))
        let graded = try #require(html.range(of: "/notebook-graded.js"))
        #expect(guide.lowerBound < graded.lowerBound)
    }
}
