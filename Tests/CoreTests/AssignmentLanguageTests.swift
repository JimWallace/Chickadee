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
}
