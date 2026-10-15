// Tests/APITests/BirdMotionTests.swift
//
// The user's own bird moves a little (#2589): a lean on hover, a slow breath
// on the account page, and a chirp on click. All of the motion sits behind
// `prefers-reduced-motion: no-preference`, and the chirp is wired by
// `Public/bird-chirp.js`, whose own behaviour is under node --test.

import ChickadeeTestSupport
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct BirdMotionTests {

    @Test func theAccountPageWiresTheChirp() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.contains("class=\"bird-card-hero\" data-bird-chirp"))
            #expect(html.contains("/bird-chirp.js"))
        }
    }

    /// Every rule that starts the breath or the lean is inside the
    /// reduced-motion guard, so a reader who asked for less motion sees a
    /// still bird.
    @Test func theMotionIsOnlyForReadersWhoDidNotAskForLess() throws {
        let css = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Public/styles.css"), encoding: .utf8)
        let guardOpen = "@media (prefers-reduced-motion: no-preference) {"
        let guarded = css.components(separatedBy: guardOpen).dropFirst().map { block in
            // The block runs to the first line that closes it at column 0.
            block.components(separatedBy: "\n}\n").first ?? ""
        }
        let unguarded = css.components(separatedBy: guardOpen).enumerated().map { index, chunk in
            index == 0 ? chunk : (chunk.components(separatedBy: "\n}\n").dropFirst().joined(separator: "\n}\n"))
        }.joined()

        #expect(guarded.contains { $0.contains("animation: bird-breathe") })
        #expect(guarded.contains { $0.contains("transform: rotate(-8deg)") })
        #expect(!unguarded.contains("animation: bird-breathe"))
        #expect(!unguarded.contains("rotate(-8deg)"))
    }
}
