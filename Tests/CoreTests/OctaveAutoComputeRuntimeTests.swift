// Tests/CoreTests/OctaveAutoComputeRuntimeTests.swift
//
// The Octave sibling of LuaAutoComputeRuntimeTests, and it exists for the same
// reason: `AssignmentLanguage.autoComputeRuntimeSource` is composed in Swift and
// re-composed in `Tools/browser-grading-smoke/auto-compute-runtime.mjs`, so the
// smoke and the Node execution suite probe what actually ships. Add a piece on
// one side only and the browser tests keep passing against a runtime that is
// missing it.

import Foundation
import Testing

@testable import Core

@Suite struct OctaveAutoComputeRuntimeTests {

    /// The pieces, in order. A literal list rather than a re-derivation, because
    /// a test that recomputed the implementation would agree with any change.
    private static let pieces: [String] = [
        OctavePersonalizationRuntime.chickadeeSerializeOctaveSource,
        OctavePersonalizationRuntime.chickadeeEscapeStringOctaveSource,
    ]

    @Test func theSeededRuntimeIsExactlyTheTwoSharedConstants() throws {
        let composed = try #require(AssignmentLanguage.octave.autoComputeRuntimeSource)
        #expect(
            composed == Self.pieces.joined(separator: "\n\n"),
            """
            The Octave auto-compute runtime changed shape.

            Tools/browser-grading-smoke/auto-compute-runtime.mjs rebuilds these bytes
            from the same Swift constants, for the browser-grading smoke and for
            Tests/BrowserRunnerJSTests/octave-eval-execution.test.mjs. Update its
            COMPOSITION table to match, or those suites will keep passing against a
            runtime the server no longer sends.
            """)
    }

    /// Both pieces are `function` definitions, which is what makes the eval
    /// worker's `1;` guard load-bearing: without it the boot cell reads as a
    /// function FILE and nothing registers. `octave-eval-shared.js` supplies the
    /// guard; this pins the premise it rests on.
    @Test func theRuntimeIsNothingButFunctionDefinitions() throws {
        let composed = try #require(AssignmentLanguage.octave.autoComputeRuntimeSource)
        #expect(composed.hasPrefix("function "))
        #expect(composed.contains("function s = chickadee_serialize(value)"))
        #expect(composed.contains("function s = chickadee_escape_string(value)"))
    }

    /// A descriptor claiming a worker that is not there makes the editor spawn a
    /// 404 and auto-compute stop with no message, so the flip is pinned rather
    /// than left to a reader to notice.
    @Test func octaveDeclaresItsInPageWorker() {
        #expect(
            AssignmentLanguage.octave.descriptor.autoCompute
                == .inPageKernel(workerScript: "/octave-eval-worker.js"))
    }

    /// Every language with a vendored editor kernel now computes in the page.
    /// The two that route to the server are the two with no kernel to run — a
    /// property of the language, not a gap left to close.
    @Test func onlyTheKernellessLanguagesRouteToTheServer() {
        for language in AssignmentLanguage.allCases {
            let usesServer = language.descriptor.autoCompute == .serverDriver
            let hasEditorKernel = language.descriptor.editorSupport != .uploadOnly
            #expect(
                usesServer != hasEditorKernel,
                "\(language): a language with an editor kernel should compute in the page")
        }
    }
}
