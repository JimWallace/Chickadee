// Tests/APITests/NotebookBootPanelTests.swift
//
// The notebook editor's loading panel (NB1, design frame 18e): what the
// notebook body renders over the editor, and the two facts the routes give
// it — the declared language's name and the viewer's bird.

import Core
import Elementary
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookBootPanelTests {

    private func manifest(language: String?) -> String {
        let declared = language.map { ",\"language\":\"\($0)\"" } ?? ""
        return """
            {"schemaVersion":1,"gradingMode":"browser"\(declared),"requiredFiles":[],\
            "testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10}
            """
    }

    private func render(kernelLanguage: String?, bird: AvatarPresentation?) -> String {
        var body = ElementaryPageFixtures.notebookBody(.init(showSubmit: true))
        body.kernelLanguage = kernelLanguage
        body.bootBird = bird
        return body.render()
    }

    private func bird(isStaff: Bool = false) throws -> AvatarPresentation {
        let json = try #require(AvatarStore.encode(AvatarSpec.drawn(fromSeed: 7)))
        return try #require(NotebookBootFacts.bird(avatarSpecJSON: json, isStaff: isStaff))
    }

    // MARK: - The language the panel names

    @Test(arguments: [("python", "Python"), ("r", "R"), ("lua", "Lua"), ("octave", "Octave")])
    func aLanguageWithAnEditorKernelIsNamed(raw: String, name: String) {
        #expect(NotebookBootFacts.kernelLanguage(manifestJSON: manifest(language: raw)) == name)
    }

    @Test(arguments: ["cpp", "racket", "java"])
    func anUploadOnlyLanguageIsNotNamed(raw: String) {
        #expect(NotebookBootFacts.kernelLanguage(manifestJSON: manifest(language: raw)) == nil)
    }

    @Test func noDeclaredLanguageAndABrokenManifestAreNotNamed() {
        #expect(NotebookBootFacts.kernelLanguage(manifestJSON: manifest(language: nil)) == nil)
        #expect(NotebookBootFacts.kernelLanguage(manifestJSON: "not json") == nil)
    }

    // MARK: - The bird

    @Test func theBirdIsTheStoredOneWithTheCuriousFaceAtTheHeroSize() throws {
        let spec = AvatarSpec.drawn(fromSeed: 7)
        let stored = AvatarPresentation(for: spec, size: .hero, accessibility: .decorative, isStaff: false)
        let shown = try bird()
        #expect(shown.expressionSymbolRef == "#av-expression-curious")
        #expect(shown.sizeClass == "avatar avatar-lg")
        #expect(shown.label == nil)
        #expect(shown.plumageSymbolRef == stored.plumageSymbolRef)
        #expect(shown.capToken == stored.capToken)
    }

    @Test func staffWearTheStaffRing() throws {
        #expect(try bird(isStaff: true).ringSymbolRef == "#av-ring-staff")
    }

    @Test func noStoredBirdShowsNoBird() {
        #expect(NotebookBootFacts.bird(avatarSpecJSON: nil, isStaff: true) == nil)
        #expect(NotebookBootFacts.bird(avatarSpecJSON: "{}", isStaff: false) == nil)
    }

    // MARK: - The rendered panel

    @Test func thePanelSitsOverTheEditorWithTheFirstStepActive() throws {
        let html = render(kernelLanguage: "Python", bird: nil)
        let stage = try #require(html.range(of: "<div class=\"nb-stage\">"))
        let panel = try #require(html.range(of: "id=\"nb-boot\""))
        let frame = try #require(html.range(of: "id=\"jl-frame\""))
        #expect(stage.lowerBound < panel.lowerBound)
        #expect(panel.lowerBound < frame.lowerBound)
        #expect(html.contains("Starting Python in your browser"))
        #expect(html.contains("<li data-boot-step=\"editor\" data-state=\"active\">Load the editor</li>"))
        #expect(html.contains("<li data-boot-step=\"kernel\" data-state=\"pending\">Download and start Python</li>"))
        #expect(html.contains("<li data-boot-step=\"notebook\" data-state=\"pending\">Open your notebook</li>"))
        #expect(html.contains("Next time is faster, because your browser keeps the download."))
        #expect(html.contains("aria-live=\"polite\""))
        #expect(!html.contains("nb-boot-bird"))
    }

    @Test func theToolbarShowsTheKernelStarting() {
        let html = render(kernelLanguage: "R", bird: nil)
        #expect(html.contains("id=\"nb-kernel-chip\" class=\"kernel-chip\" data-state=\"starting\""))
        #expect(html.contains("R · <span class=\"js-nb-kernel-state\">starting</span>"))
    }

    @Test func noLanguageNamesTheKernel() {
        let html = render(kernelLanguage: nil, bird: nil)
        #expect(html.contains("Starting the notebook in your browser"))
        #expect(html.contains("Download and start the kernel"))
        #expect(html.contains("Kernel · <span class=\"js-nb-kernel-state\">starting</span>"))
    }

    @Test func theBirdIsDecorativeAndPecksAtThreeSeeds() throws {
        let html = render(kernelLanguage: "Python", bird: try bird())
        #expect(html.contains("<div class=\"nb-boot-bird\" aria-hidden=\"true\">"))
        #expect(html.contains("#av-expression-curious"))
        #expect(html.contains("<div class=\"nb-boot-seeds\"><span></span><span></span><span></span></div>"))
    }

    @Test func theBootScriptLoadsBeforeThePreflight() throws {
        let html = render(kernelLanguage: nil, bird: nil)
        let boot = try #require(html.range(of: "/notebook-boot.js"))
        let preflight = try #require(html.range(of: "/notebook-preflight-core.js"))
        #expect(boot.lowerBound < preflight.lowerBound)
    }
}
