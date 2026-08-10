// Tests/CoreTests/LuaAutoComputeRuntimeTests.swift
//
// The Lua auto-compute runtime is composed in Swift and re-composed in
// JavaScript. `AssignmentLanguage.autoComputeRuntimeSource` is what the server
// sends the in-page eval worker; `Tools/browser-grading-smoke/auto-compute-runtime.mjs`
// rebuilds the same bytes from the same constants so the smoke and the Node
// execution suite probe what actually ships rather than a paraphrase of it.
//
// That is two statements of one composition, and the failure mode is quiet: add
// a fifth piece in Swift and the browser tests keep passing against a runtime
// that is missing it. This suite is the guard — it fails on the Swift side and
// names the file to update.

import Foundation
import Testing

@testable import Core

@Suite struct LuaAutoComputeRuntimeTests {

    /// The pieces, in order. Kept as a literal list rather than derived from the
    /// implementation, because a test that recomputed the implementation would
    /// agree with any change.
    private static let pieces: [String] = [
        LuaPersonalizationRuntime.chickadeeNullTableLuaSource,
        LuaPersonalizationRuntime.chickadeeSerializeLuaSource,
        LuaPersonalizationRuntime.chickadeeJSONStringLuaSource,
        LuaPersonalizationRuntime.chickadeeAutoComputeExportsLuaSource,
    ]

    @Test func theSeededRuntimeIsExactlyTheFourSharedConstants() throws {
        let composed = try #require(AssignmentLanguage.lua.autoComputeRuntimeSource)
        #expect(
            composed == Self.pieces.joined(separator: "\n\n"),
            """
            The Lua auto-compute runtime changed shape.

            Tools/browser-grading-smoke/auto-compute-runtime.mjs rebuilds these bytes
            from the same Swift constants, for the browser-grading smoke and for
            Tests/BrowserRunnerJSTests/lua-eval-execution.test.mjs. Update its
            COMPOSITION table to match, or those suites will keep passing against a
            runtime the server no longer sends.
            """)
    }

    /// The two helpers are declared `local`, which is correct for the server
    /// driver (one script, one chunk) and fatal in a kernel, where every cell is
    /// its own chunk. The exports tail is what bridges that, and it has to come
    /// last: it is the only place the locals are still in scope.
    @Test func theHelpersAreExportedAfterTheyAreDeclared() throws {
        let composed = try #require(AssignmentLanguage.lua.autoComputeRuntimeSource)
        for helper in ["chickadee_serialize", "chickadee_json_str"] {
            let declaration = try #require(composed.range(of: "local function \(helper)"))
            let export = try #require(composed.range(of: "_G.\(helper) = \(helper)"))
            #expect(
                declaration.lowerBound < export.lowerBound,
                "\(helper) is exported before it is declared, so the export binds nil")
        }
    }

    /// The sentinel a rendered argument may name. The eval worker loads no
    /// `test_runtime`, so if this is not seeded, a case containing a JSON null
    /// indexes a nil `chickadee` and reports as a solution error.
    @Test func theNullSentinelIsSeededBeforeAnythingCanReferenceIt() throws {
        let composed = try #require(AssignmentLanguage.lua.autoComputeRuntimeSource)
        #expect(composed.hasPrefix("chickadee = chickadee or {}"))
        #expect(composed.contains("chickadee.NULL = chickadee.NULL or setmetatable("))
        // The literal renderer's output has to name what is seeded here.
        #expect(JSONValue.array([.null]).luaLiteral == "{chickadee.NULL}")
    }

    /// The one language whose descriptor still routes auto-compute to the server
    /// alongside C++ and Racket is Octave, and only until its worker exists.
    /// Pinned so flipping Lua's substrate cannot be half-done — a descriptor
    /// claiming a worker that is not there makes the editor spawn a 404 and
    /// auto-compute stop with no message.
    @Test func luaDeclaresItsInPageWorker() {
        #expect(
            AssignmentLanguage.lua.descriptor.autoCompute
                == .inPageKernel(workerScript: "/lua-eval-worker.js"))
    }
}
