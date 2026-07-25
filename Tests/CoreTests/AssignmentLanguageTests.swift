import Foundation
import Testing

@testable import Core

@Suite struct AssignmentLanguageTests {
    private func manifest(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    @Test func rScriptImpliesR() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.R"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m) == .r)
    }

    @Test func pyScriptImpliesPython() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.py"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m) == .python)
    }

    @Test func rScriptWinsOverPythonKernel() throws {
        // The graded suite is authoritative: an .R test means R even if a stray
        // notebook kernel says otherwise.
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.R"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m, notebookKernelName: "python") == .r)
    }

    @Test func kernelNameFallbackWhenNoScripts() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m, notebookKernelName: "xr") == .r)
        #expect(AssignmentLanguage.resolve(manifest: m, notebookKernelName: "ir") == .r)
        #expect(AssignmentLanguage.resolve(manifest: m, notebookLanguageInfoName: "r") == .r)
        #expect(AssignmentLanguage.resolve(manifest: m) == .python)
    }

    // MARK: - rederive (ignores the recorded language memo)

    private func ipynb(kernel: String?) -> Data {
        let kernelField = kernel.map { "\"kernelspec\":{\"name\":\"\($0)\"}" } ?? ""
        return Data("{\"metadata\":{\(kernelField)},\"cells\":[]}".utf8)
    }

    @Test func rederive_rScriptWinsOverRecordedPythonAndPythonKernel() throws {
        // Recorded .python + a Python notebook kernel, but an .R graded script:
        // rederive skips the recorded memo and the suite wins.
        let m = try manifest(
            #"{"schemaVersion":1,"language":"python","requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.R"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: "python")) == .r)
    }

    @Test func rederive_rNotebookKernelWinsOverRecordedPython() throws {
        // The one-way-door case: recorded .python, no .R script, but the new
        // notebook is an R kernel — rederive returns .r where resolve stays .python.
        let m = try manifest(
            #"{"schemaVersion":1,"language":"python","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: "xr")) == .r)
        #expect(AssignmentLanguage.resolve(manifest: m, notebookData: ipynb(kernel: "xr")) == .python)
    }

    @Test func rederive_pythonNotebookIgnoresRecordedR() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"language":"r","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: "python")) == .python)
    }

    @Test func rederive_noNotebookDefaultsPython() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"language":"r","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: nil) == .python)
    }
}
