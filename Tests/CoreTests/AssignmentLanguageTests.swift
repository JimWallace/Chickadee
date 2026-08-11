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
        // No suite and no kernel name: nothing names a language, which is nil
        // rather than Python. Conflating those two was the whole defect class.
        #expect(AssignmentLanguage.resolve(manifest: m) == nil)
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

    /// `rederive` ignores the recorded memo by design, so a manifest that
    /// records R but has no suite and no notebook re-derives to NOTHING — the
    /// memo is the only thing that claimed a language, and re-derivation is
    /// exactly the operation that refuses to trust it.
    @Test func rederive_noNotebookResolvesToNoLanguage() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"language":"r","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: nil) == nil)
    }

    // MARK: - Lua resolution (the F1 regression: resolve/rederive were R-only,
    // so a real Lua assignment resolved to Python everywhere server-side).

    @Test func luaScriptImpliesLua() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.lua"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m) == .lua)
    }

    @Test func luaKernelFallbackWhenNoScripts() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.resolve(manifest: m, notebookKernelName: "xlua") == .lua)
        #expect(AssignmentLanguage.resolve(manifest: m, notebookLanguageInfoName: "lua") == .lua)
    }

    @Test func rederive_luaNotebookKernelWinsOverRecordedPython() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"language":"python","requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: "xlua")) == .lua)
    }

    @Test func rederive_luaScriptWinsOverRecordedPython() throws {
        let m = try manifest(
            #"{"schemaVersion":1,"language":"python","requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.lua"}],"timeLimitSeconds":10}"#
        )
        #expect(AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: "python")) == .lua)
    }

    // MARK: - allCases-driven: the guard that would have caught F1. Every
    // language must be resolvable from its own graded script and its own
    // notebook kernel — no language may silently fall through to Python.

    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageResolvesFromItsOwnGradedScript(_ language: AssignmentLanguage) throws {
        // C++ is the deliberate exception: its generated scripts are `.sh`
        // wrappers, and `.sh` must carry NO language signal (every hand-written
        // shell suite would sniff as C++ otherwise). Its resolution signal is
        // the RECORDED manifest language — asserted here, along with the
        // no-signal pin for the bare script. That pin is now nil rather than
        // Python: a `.sh`-only suite is the canonical language-less assignment,
        // and saying so is the point of the Optional.
        guard language != .cpp else {
            let bare = try manifest(
                #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.sh"}],"timeLimitSeconds":10}"#
            )
            #expect(AssignmentLanguage.resolve(manifest: bare) == nil)
            let recorded = try manifest(
                #"{"schemaVersion":1,"language":"cpp","requiredFiles":[],"testSuites":[{"tier":"public","script":"publictest_x.sh"}],"timeLimitSeconds":10}"#
            )
            #expect(AssignmentLanguage.resolve(manifest: recorded) == .cpp)
            return
        }
        let script = "publictest_x.\(language.generatedScriptExtension)"
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"\#(script)"}],"timeLimitSeconds":10}"#
        )
        #expect(
            AssignmentLanguage.resolve(manifest: m) == language,
            "a \(script) graded script must resolve to \(language), not fall through to Python")
    }

    @Test(arguments: AssignmentLanguage.allCases)
    func everyLanguageResolvesFromItsOwnKernel(_ language: AssignmentLanguage) throws {
        // Python is included: it has its own `notebookKernelNames` now and
        // resolves positively like every other language. A language with no
        // kernel at all (C++, upload-only) has an empty set and asserts nothing.
        let m = try manifest(
            #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
        )
        for kernel in language.notebookKernelNames {
            #expect(
                AssignmentLanguage.resolve(manifest: m, notebookKernelName: kernel) == language,
                "kernel `\(kernel)` must resolve to \(language)")
            #expect(
                AssignmentLanguage.rederive(manifest: m, notebookData: ipynb(kernel: kernel))
                    == language,
                "rederive of a `\(kernel)` notebook must be \(language)")
        }
    }

    // MARK: - The extension scan behind `gradedScriptLanguage`

    /// The resolution walk no longer builds a `URL` per suite entry to read a
    /// file extension — `URL(fileURLWithPath:).pathExtension` measured 4.5 µs
    /// per call on Linux Foundation, and the walk called it once per entry per
    /// language, which is where a plain 40-entry `.sh` suite's 1.27 ms went.
    ///
    /// A DIFFERENTIAL, not an example list, because the first hand-rolled scan
    /// passed every example anyone would think to write (`.gitignore`, `a.R`,
    /// `dir/x.py`) and still disagreed with Foundation on `..R`. Names are
    /// generated from fragments chosen to collide with the rule's corners:
    /// leading dots, repeated dots, separators, and each language's own
    /// extension in both cases.
    ///
    /// Dotfiles are EXCLUDED and pinned separately below, because Foundation's
    /// answer for them is not a rule — see the scan's own doc comment for the
    /// measured table.
    @Test func scriptExtensionScanAgreesWithFoundation() throws {
        let fragments = ["a", "R", "py", "sh", "lua", "m", "rkt", "cpp", "PY", ".", "/", "", "x.y", "..", "-"]
        var names: [String] = [""]
        for _ in 0..<3 {
            names = names.flatMap { tail in fragments.map { $0 + tail } }
        }
        var compared = 0
        for name in names {
            // The divergence is stated, not accidental: a base name beginning
            // with a dot is a dotfile here, whatever Foundation says.
            let base = name.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
            if base.hasPrefix(".") { continue }
            let viaFoundation = AssignmentLanguage(
                scriptExtension: URL(fileURLWithPath: name).pathExtension)
            let props = TestProperties(
                requiredFiles: [],
                testSuites: [TestSuiteEntry(tier: .pub, script: name)],
                timeLimitSeconds: 10)
            compared += 1
            #expect(
                AssignmentLanguage.resolve(manifest: props) == viaFoundation,
                """
                The extension scan and URL.pathExtension disagree about \(name.debugDescription): \
                scan says \(String(describing: AssignmentLanguage.resolve(manifest: props))), \
                Foundation says \(String(describing: viaFoundation)).
                """)
        }
        #expect(compared > 2000, "the differential must actually generate names, not skip them all")
    }

    /// The dotfile rule, pinned. `....R` is the one Foundation calls an R file
    /// and this does not; the assertion exists so that divergence is a decision
    /// someone can find and argue with rather than a silent difference.
    @Test(arguments: [".R", ".gitignore", "..R", "...R", "....R", "dir/.py"])
    func aDotfileNeverClaimsALanguage(_ script: String) {
        let props = TestProperties(
            requiredFiles: [],
            testSuites: [TestSuiteEntry(tier: .pub, script: script)],
            timeLimitSeconds: 10)
        #expect(
            AssignmentLanguage.resolve(manifest: props) == nil,
            "\(script) is a hidden file and must not resolve a language")
    }

    /// `allCases` order still breaks a tie, and it is now applied to what the
    /// single pass found rather than driving the search. A mixed suite resolves
    /// to the earliest case present regardless of the order the entries appear
    /// in — the property the old `allCases.first { suites.contains { … } }`
    /// shape provided for free and the rewrite had to preserve deliberately.
    @Test func aMixedSuiteResolvesInAllCasesOrderNotSuiteOrder() {
        let scripts = ["publictest_a.lua", "publictest_b.R", "publictest_c.rkt"]
        for rotation in 0..<scripts.count {
            let rotated = Array(scripts[rotation...] + scripts[..<rotation])
            let props = TestProperties(
                requiredFiles: [],
                testSuites: rotated.map { TestSuiteEntry(tier: .pub, script: $0) },
                timeLimitSeconds: 10)
            #expect(
                AssignmentLanguage.resolve(manifest: props) == .r,
                "suite order \(rotated) must not change the resolved language")
        }
    }
}
