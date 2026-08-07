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

    /// A manifest whose only graded script is written in `language`, i.e. the
    /// shape a real assignment in that language has.
    private func manifest(gradedScriptIn language: AssignmentLanguage) throws -> TestProperties {
        let script = "publictest_walk.\(language.generatedScriptExtension)"
        let json = """
            {"schemaVersion":1,"requiredFiles":[],\
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
        let resolved = AssignmentLanguage.resolve(manifest: props, notebookData: nil)
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

        // 3. NOTEBOOK CHECK — every language renders at least one kind, and it
        //    lands on the same extension.
        let supported = NotebookCheckKind.allCases.filter {
            !(GeneratedSourceFixtures.notebookCheckKindExceptions[resolved] ?? []).contains($0)
        }
        let checkKind = try #require(supported.first, "\(resolved) supports no notebook check kind")
        let check = renderNotebookCheck(GeneratedSourceFixtures.check(kind: checkKind), language: resolved)
        #expect(
            check.script.filename.hasSuffix(".\(resolved.generatedScriptExtension)"),
            "\(resolved)/\(checkKind) generated \(check.script.filename)")

        // 4. PER-STUDENT INPUTS — the filename the worker writes must be the one
        //    this language's runtime reads. F5's browser twin wrote Python's.
        let inputs = resolved.renderInputsFile(["threshold": resolved.literal(.int(42))])
        #expect(!inputs.isEmpty, "\(resolved) rendered an empty inputs file")
        #expect(
            resolved.inputsFileName.hasSuffix(".\(resolved.generatedScriptExtension)")
                || resolved.inputsFileName.lowercased()
                    .hasSuffix(".\(resolved.generatedScriptExtension.lowercased())"),
            """
            \(resolved) writes \(resolved.inputsFileName), which is not a \
            .\(resolved.generatedScriptExtension) file — the runtime loads it as source, so the \
            extension has to match the language.
            """)

        // 5. EDITOR KERNEL — the notebook this language's students open must
        //    normalize onto a kernel the editor can attach. The leg F6 broke.
        let normalized = normalizeNotebookForJupyterLite(notebook(for: resolved))
        let object = try #require(
            (try? JSONSerialization.jsonObject(with: normalized)) as? [String: Any])
        let kernelspec = try #require(
            (object["metadata"] as? [String: Any])?["kernelspec"] as? [String: Any])
        #expect(
            kernelspec["name"] as? String == resolved.descriptor.jupyterLiteKernelName,
            """
            A \(resolved) notebook normalized to \(kernelspec["name"] as? String ?? "nil") rather \
            than \(resolved.descriptor.jupyterLiteKernelName), so the editor cannot attach a \
            kernel to it.
            """)
    }

    /// The notebook half of leg 1: a language with positive kernel aliases must
    /// resolve from its notebook alone, which is the only signal a brand-new
    /// notebook assignment has (empty suite, nothing recorded).
    @Test(arguments: AssignmentLanguage.allCases)
    func aBrandNewNotebookAssignmentResolvesFromItsKernel(_ expected: AssignmentLanguage) throws {
        guard expected != .default else { return }  // no positive aliases by design
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
