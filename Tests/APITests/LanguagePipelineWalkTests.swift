// Tests/APITests/LanguagePipelineWalkTests.swift
//
// One end-to-end walk per language, along the chain a real assignment actually
// travels: resolve → render a family → render a check → write the inputs file →
// normalize the notebook for the editor. Every step is asserted against the
// language the FIRST step resolved, not against a language the test supplied.
//
// WHY THIS SHAPE. The existing matrix (LanguageConformanceMatrixTests) proves
// each stage works when handed `.lua` explicitly. That is necessary and it is
// not sufficient: every defect in docs/lua-architecture-audit.md sat in the
// JOINT between stages, where something asked "which language is this?" and
// answered Python —
//
//   * F1: `resolve`/`rederive` string-matched `.R` and rKernelNames, so a Lua
//     assignment resolved to Python and every downstream stage was handed the
//     wrong language. Nothing failed, because nothing asked resolution anything.
//   * F5: the browser made the same mistake independently.
//   * F6: `normalizeNotebookForJupyterLite` had no Lua arm.
//
// A test that starts from a manifest and walks forward catches that class: the
// language is DISCOVERED at step 1 and carried, so a stage that disagrees with
// resolution fails here rather than silently grading as Python.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct LanguagePipelineWalkTests {

    /// A manifest whose only graded script is written in `language`, in the
    /// minimal REAL shape that identifies that language.
    ///
    /// For the four kernel languages that shape is the script extension alone
    /// — kept unrecorded here so this walk goes on guarding extension
    /// resolution (the F1 leg). C++ is different by design: its generated
    /// scripts are plain `.sh` precisely so the extension carries no language
    /// signal, which means a real C++ manifest is identified by its RECORDED
    /// `language` field and nothing else. The fixture includes the recorded
    /// field exactly when the extension cannot answer, so a future
    /// signal-free language takes this branch automatically.
    private func manifest(gradedScriptIn language: AssignmentLanguage) throws -> TestProperties {
        let script = "publictest_walk.\(language.generatedScriptExtension)"
        let extensionIdentifies = language.scriptExtensions.contains(
            language.generatedScriptExtension.lowercased())
        let recordedField = extensionIdentifies ? "" : #""language":"\#(language.rawValue)","#
        let json = """
            {"schemaVersion":1,\(recordedField)"requiredFiles":[],\
            "testSuites":[{"tier":"public","script":"\(script)"}],"timeLimitSeconds":10}
            """
        return try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    /// A notebook carrying `language`'s own kernel, or a bare Python one for the
    /// default (which has no positive aliases).
    private func notebook(for language: AssignmentLanguage) -> Data {
        let kernel = language.notebookKernelNames.min() ?? "python3"
        let json = """
            {"nbformat":4,"metadata":{"kernelspec":{"name":"\(kernel)"}},"cells":[]}
            """
        return Data(json.utf8)
    }

    /// THE WALK. Each leg consumes the language the previous leg produced.
    @Test(arguments: AssignmentLanguage.allCases)
    func theWholePipelineAgreesOnTheLanguage(_ expected: AssignmentLanguage) throws {
        // 1. RESOLUTION — the leg F1 broke. Everything after this consumes
        //    `resolved`, never `expected`, so a resolution that answers Python
        //    fails the legs below rather than quietly grading as Python.
        let props = try manifest(gradedScriptIn: expected)
        let resolved = try #require(
            AssignmentLanguage.resolve(manifest: props, notebookData: nil),
            """
            A manifest whose only graded script is a \(expected) script resolved to NO language. \
            Resolution is Optional, and nil means "nothing here names a language" — a graded \
            script in the language is exactly the signal that must not produce it.
            """)
        #expect(
            resolved == expected,
            """
            A manifest whose only graded script is \
            `publictest_walk.\(expected.generatedScriptExtension)` resolved to \(resolved). \
            Everything downstream — renderers, the inputs file, the expression driver — is \
            handed this answer, so a wrong one grades the assignment as \(resolved).
            """)

        // 2. PATTERN FAMILY — rendered for the RESOLVED language.
        let familyScripts = renderPatternFamily(
            GeneratedSourceFixtures.family(kind: .boundaryEquality), language: resolved)
        #expect(!familyScripts.isEmpty, "\(resolved) rendered no family scripts")
        for script in familyScripts {
            #expect(
                script.filename.hasSuffix(".\(resolved.generatedScriptExtension)"),
                "\(resolved) generated \(script.filename), which is not a \(resolved) script")
        }

        // 3. NOTEBOOK CHECK — a language that supports any check kind renders
        //    one onto its own extension. C++ supports none, categorically —
        //    there is no notebook workflow to check — and for it this leg's
        //    assertion is that the refusal really is the WHOLE set, not a
        //    partial list someone forgot to finish.
        let supported = NotebookCheckKind.allCases.filter {
            !(GeneratedSourceFixtures.notebookCheckKindExceptions[resolved] ?? []).contains($0)
        }
        if let checkKind = supported.first {
            let check = renderNotebookCheck(
                GeneratedSourceFixtures.check(kind: checkKind), language: resolved)
            #expect(
                check.script.filename.hasSuffix(".\(resolved.generatedScriptExtension)"),
                "\(resolved)/\(checkKind) generated \(check.script.filename)")
        } else {
            #expect(
                GeneratedSourceFixtures.notebookCheckKindExceptions[resolved]?.count
                    == NotebookCheckKind.allCases.count,
                "\(resolved) supports no check kind, but its exclusion list is partial")
        }

        // 4. PER-STUDENT INPUTS — the filename the worker writes must be the one
        //    this language's runtime reads. F5's browser twin wrote Python's.
        //    The extension coupling holds for the interpreted languages, whose
        //    inputs file IS source the runtime loads; C++'s is a HEADER
        //    (`_ck_inputs.hpp`) compiled into the generated test's translation
        //    unit beside `.sh` wrappers, so the coupling deliberately does not
        //    hold there — the conformance matrix's compile-and-run inputs leg
        //    proves its delivery instead.
        let inputs = resolved.renderInputsFile(["threshold": resolved.literal(.int(42))])
        #expect(!inputs.isEmpty, "\(resolved) rendered an empty inputs file")
        if resolved != .cpp {
            #expect(
                resolved.inputsFileName.lowercased()
                    .hasSuffix(".\(resolved.generatedScriptExtension.lowercased())"),
                """
                \(resolved) writes \(resolved.inputsFileName), which is not a \
                .\(resolved.generatedScriptExtension) file — the runtime loads it as source, so \
                the extension has to match the language.
                """)
        }

        // 5. EDITOR KERNEL — the notebook this language's students open must
        //    normalize onto a kernel the editor can attach. The leg F6 broke.
        //    A kernel-less (upload-only) language has no notebook workflow, so
        //    this leg does not apply to it — the walk's earlier legs already
        //    covered everything such a language does.
        guard case .notebookKernel(_, let expectedKernel, _, _) = resolved.editorSupport else {
            return
        }
        let normalized = normalizeNotebookForJupyterLite(notebook(for: resolved))
        let object = try #require(
            (try? JSONSerialization.jsonObject(with: normalized)) as? [String: Any])
        let kernelspec = try #require(
            (object["metadata"] as? [String: Any])?["kernelspec"] as? [String: Any])
        #expect(
            kernelspec["name"] as? String == expectedKernel,
            """
            A \(resolved) notebook normalized to \(kernelspec["name"] as? String ?? "nil") rather \
            than \(expectedKernel), so the editor cannot attach a kernel to it.
            """)
    }

    /// The notebook half of leg 1: a language with positive kernel aliases must
    /// resolve from its notebook alone, which is the only signal a brand-new
    /// notebook assignment has (empty suite, nothing recorded).
    @Test(arguments: AssignmentLanguage.allCases)
    func aBrandNewNotebookAssignmentResolvesFromItsKernel(_ expected: AssignmentLanguage) throws {
        // Python is included now — it has its own aliases. A language with no
        // kernel at all (C++, upload-only) has an empty set and asserts nothing.
        let empty = try JSONDecoder().decode(
            TestProperties.self,
            from: Data(
                #"{"schemaVersion":1,"requiredFiles":[],"testSuites":[],"timeLimitSeconds":10}"#
                    .utf8))
        for alias in expected.notebookKernelNames {
            let json = #"{"nbformat":4,"metadata":{"kernelspec":{"name":"\#(alias)"}},"cells":[]}"#
            let resolved = AssignmentLanguage.resolve(
                manifest: empty, notebookData: Data(json.utf8))
            #expect(
                resolved == expected,
                """
                A brand-new assignment whose starter notebook carries the `\(alias)` kernel \
                resolved to \(resolved). Its suite is empty and nothing is recorded, so the \
                kernel is the only signal there is — getting it wrong is sticky, because the \
                first save records the resolved language.
                """)
        }
    }
}
