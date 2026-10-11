import Foundation
import Leaf
import Testing
import VaporTesting

@testable import APIServer

/// `useChickadeeConfiguration` makes a missing `#export` slot an error. Leaf's
/// default renders nothing in its place, so a page that forgot its title or
/// content would serve an empty one without a sound.
@Suite(.timeLimit(.minutes(1))) struct LeafStrictImportTests {

    private func withViews(_ files: [String: String], _ body: (Application) async throws -> Void) async throws {
        let directory = NSTemporaryDirectory() + "chickadee-strict-import-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        for (name, source) in files {
            try source.write(toFile: directory + name + ".leaf", atomically: true, encoding: .utf8)
        }
        let app = try await Application.make(.testing)
        app.leaf.useChickadeeConfiguration(rootDirectory: directory)
        app.views.use(.leaf)
        try await withApp(app) { app in try await body(app) }
    }

    private static let layout = "<title>#import(\"title\")</title><main>#import(\"content\")</main>"

    @Test func aPageThatExportsEverySlotRenders() async throws {
        let page = #"#extend("layout"):#export("title"):T#endexport#export("content"):C#endexport#endextend"#
        try await withViews(["layout": Self.layout, "page": page]) { app in
            let view = try await app.view.render("page")
            #expect(String(buffer: view.data) == "<title>T</title><main>C</main>")
        }
    }

    @Test func aPageThatForgetsASlotFailsLoudly() async throws {
        let page = #"#extend("layout"):#export("content"):C#endexport#endextend"#
        try await withViews(["layout": Self.layout, "page": page]) { app in
            await #expect(throws: (any Error).self) {
                _ = try await app.view.render("page")
            }
        }
    }
}
