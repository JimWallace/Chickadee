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

    /// Every alias of every non-default language normalizes to that language's
    /// vendored kernel — the guard whose absence let a Lua notebook keep a
    /// `lua` kernelspec the editor cannot attach.
    ///
    /// The expected kernel comes from the DESCRIPTOR rather than a table here:
    /// a hand-maintained map in the test is the same enumerated shape as the
    /// hand-written arms this replaced, and it would need editing for a fourth
    /// language exactly when it should be failing instead.
    @Test(arguments: AssignmentLanguage.allCases)
    func everyKernelAliasNormalizesToItsVendoredKernel(_ language: AssignmentLanguage) throws {
        guard language != .default else { return }  // Python has no positive aliases
        guard case .notebookKernel(_, let expected, _, _) = language.editorSupport else {
            // A kernel-less language must claim no aliases at all — an alias
            // with nothing to normalize onto is exactly the F6 shape.
            #expect(
                language.notebookKernelNames.isEmpty,
                "\(language) claims kernel aliases but vendors no kernel")
            return
        }
        for alias in language.notebookKernelNames {
            #expect(
                try kernelName(afterNormalizing: alias) == expected,
                "a `\(alias)` notebook must normalize to \(expected) so the editor attaches it")
        }
    }

    /// The vendored kernel names must be distinct, or two languages' notebooks
    /// would attach the same kernel — a copied descriptor literal.
    @Test func vendoredKernelNamesAreDistinct() {
        let facts = AssignmentLanguage.allCases.compactMap { language -> (String, String)? in
            guard case .notebookKernel(_, let name, let display, _) = language.editorSupport
            else { return nil }
            return (name, display)
        }
        let names = facts.map(\.0)
        #expect(Set(names).count == names.count, "two languages share a vendored kernel: \(names)")
        let labels = facts.map(\.1)
        #expect(Set(labels).count == labels.count, "two languages share a kernel label: \(labels)")
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
