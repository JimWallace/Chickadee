// Tests/APITests/NotebookKernelNormalizationTests.swift
//
// `normalizeNotebookForJupyterLite` collapses a notebook's kernelspec aliases to
// the ONE vendored kernel name the editor can attach (xr / xlua / xpython). It
// had an R arm and a Python default but no Lua arm (audit F6), so a `lua`/`xlua`
// notebook fell through "unknown → leave unchanged" and never attached xeus-lua.
// These pin every non-default language's aliases to its vendored kernel.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookKernelNormalizationTests {

    private func kernelName(afterNormalizing kernelspecName: String) throws -> String? {
        let json = #"{"nbformat":4,"metadata":{"kernelspec":{"name":"\#(kernelspecName)"}},"cells":[]}"#
        let out = normalizeNotebookForJupyterLite(Data(json.utf8))
        let obj = try #require(
            (try? JSONSerialization.jsonObject(with: out)) as? [String: Any])
        let metadata = try #require(obj["metadata"] as? [String: Any])
        let kernelspec = try #require(metadata["kernelspec"] as? [String: Any])
        return kernelspec["name"] as? String
    }

    /// The vendored kernel name each language's notebooks must normalize to.
    /// Python is the default (missing/unknown-python → xpython).
    static let vendored: [AssignmentLanguage: String] = [
        .python: jupyterLitePythonKernelName,
        .r: jupyterLiteRKernelName,
        .lua: jupyterLiteLuaKernelName,
    ]

    /// Every alias of every non-default language normalizes to that language's
    /// vendored kernel — the guard whose absence let a Lua notebook keep a
    /// `lua` kernelspec the editor cannot attach.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyKernelAliasNormalizesToItsVendoredKernel(_ language: AssignmentLanguage) throws {
        guard language != .default else { return }  // Python has no positive aliases
        let expected = try #require(Self.vendored[language])
        for alias in language.notebookKernelNames {
            #expect(
                try kernelName(afterNormalizing: alias) == expected,
                "a `\(alias)` notebook must normalize to \(expected) so the editor attaches it")
        }
    }

    @Test func luaNotebookNormalizesToXlua() throws {
        // The specific F6 regression.
        #expect(try kernelName(afterNormalizing: "lua") == "xlua")
        #expect(try kernelName(afterNormalizing: "xlua") == "xlua")
    }

    @Test func pythonAndMissingKernelsBecomeXpython() throws {
        #expect(try kernelName(afterNormalizing: "python3") == "xpython")
        let missing = normalizeNotebookForJupyterLite(
            Data(#"{"nbformat":4,"metadata":{},"cells":[]}"#.utf8))
        let obj = try #require((try? JSONSerialization.jsonObject(with: missing)) as? [String: Any])
        let kernelspec =
            (obj["metadata"] as? [String: Any])?["kernelspec"] as? [String: Any]
        #expect(kernelspec?["name"] as? String == "xpython")
    }

    @Test func genuinelyUnknownKernelIsLeftUnchanged() throws {
        #expect(try kernelName(afterNormalizing: "julia-1.9") == "julia-1.9")
    }
}
