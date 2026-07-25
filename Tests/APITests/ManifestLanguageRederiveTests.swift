// Tests/APITests/ManifestLanguageRederiveTests.swift
//
// `manifestWithRederivedLanguage` — the notebook-replacement half of the
// "recorded language is a one-way door" fix. Replacing a starter notebook
// re-derives the recorded language (a memo, not a declaration), so a Python
// assignment converted to R stops rendering `.py`. Byte-stable (returns nil)
// when the language is unchanged or was never recorded.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct ManifestLanguageRederiveTests {

    private func ipynb(kernel: String?) -> Data {
        let kernelField = kernel.map { "\"kernelspec\":{\"name\":\"\($0)\"}" } ?? ""
        return Data("{\"metadata\":{\(kernelField)},\"cells\":[]}".utf8)
    }

    private func manifestJSON(language: String?, rScript: Bool = false) -> String {
        let langField = language.map { "\"language\":\"\($0)\"," } ?? ""
        let suite = rScript ? "{\"tier\":\"public\",\"script\":\"publictest_x.R\"}" : ""
        return
            "{\"schemaVersion\":1,\(langField)\"requiredFiles\":[],\"testSuites\":[\(suite)],\"timeLimitSeconds\":10}"
    }

    @Test func flipsPythonToR_whenNotebookBecomesR() throws {
        let json = manifestJSON(language: "python")
        let updated = try #require(
            manifestWithRederivedLanguage(manifestJSON: json, notebookData: ipynb(kernel: "xr")))
        #expect(try #require(decodeManifest(fromJSON: updated)).language == .r)
    }

    @Test func flipsRToPython_whenNotebookBecomesPython() throws {
        let json = manifestJSON(language: "r")
        let updated = try #require(
            manifestWithRederivedLanguage(manifestJSON: json, notebookData: ipynb(kernel: "python")))
        #expect(try #require(decodeManifest(fromJSON: updated)).language == .python)
    }

    @Test func rScriptForcesR_evenOnPythonRecordAndPythonNotebook() throws {
        // A recorded .python alongside an .R graded script is itself wrong;
        // rederive corrects it regardless of the notebook kernel.
        let json = manifestJSON(language: "python", rScript: true)
        let updated = try #require(
            manifestWithRederivedLanguage(manifestJSON: json, notebookData: ipynb(kernel: "python")))
        #expect(try #require(decodeManifest(fromJSON: updated)).language == .r)
    }

    @Test func returnsNil_whenLanguageUnchanged() {
        // Common case: a Python notebook re-saved on a Python assignment. No
        // change, so the manifest bytes must not churn.
        let json = manifestJSON(language: "python")
        #expect(
            manifestWithRederivedLanguage(manifestJSON: json, notebookData: ipynb(kernel: "python"))
                == nil)
    }

    @Test func returnsNil_whenNoRecordedLanguage() {
        // A nil recorded language is never sticky — lazy resolution already
        // re-derives it from the notebook — so there is nothing to correct even
        // when the notebook is R.
        let json = manifestJSON(language: nil)
        #expect(
            manifestWithRederivedLanguage(manifestJSON: json, notebookData: ipynb(kernel: "xr"))
                == nil)
    }

    @Test func returnsNil_whenManifestUndecodable() {
        #expect(
            manifestWithRederivedLanguage(manifestJSON: "not json", notebookData: ipynb(kernel: "xr"))
                == nil)
    }
}
