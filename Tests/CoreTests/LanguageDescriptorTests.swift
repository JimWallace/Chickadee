// Tests/CoreTests/LanguageDescriptorTests.swift
//
// The descriptor collapsed eight parallel switches into one struct literal per
// language. That is a readability win and a fill-in-the-blank hazard in the same
// change: a literal invites copying the neighbour's and editing strings, which
// is exactly the mistake `docs/adding-a-xeus-kernel.md` exists to prevent.
//
// So these are the assertions a copied literal would fail.

import Foundation
import Testing

@testable import Core

@Suite struct LanguageDescriptorTests {

    /// Nothing in a descriptor may be blank. A copied literal with a field
    /// cleared "to fill in later" fails here rather than at grade time.
    @Test(arguments: AssignmentLanguage.allCases)
    func noDescriptorFieldIsEmpty(_ language: AssignmentLanguage) {
        let d = language.descriptor
        #expect(!d.displayName.isEmpty)
        #expect(!d.scriptExtensions.isEmpty)
        #expect(!d.generatedScriptExtension.isEmpty)
        #expect(!d.inputsFileName.isEmpty)
        #expect(!d.kernelEnvironmentFileName.isEmpty)
        #expect(!d.jupyterLiteKernelName.isEmpty)
        #expect(!d.jupyterLiteKernelDisplayName.isEmpty)
        #expect(!d.missingDependencyFailureDescription.isEmpty)
        #expect(!d.interpreterProbe.command.isEmpty)
        #expect(!d.interpreterProbe.versionArguments.isEmpty)
        // notebookKernelNames is deliberately empty for Python — it is the
        // default, reached by falling through — so it is asserted separately.
    }

    /// The fields that must not collide across languages. A copied literal
    /// whose extension or filename was left as the neighbour's would route one
    /// language's submissions to the other, silently.
    @Test func theIdentifyingFieldsAreUniqueAcrossLanguages() {
        let all = AssignmentLanguage.allCases.map(\.descriptor)
        let unique: [(String, [String])] = [
            ("displayName", all.map(\.displayName)),
            ("generatedScriptExtension", all.map(\.generatedScriptExtension)),
            ("inputsFileName", all.map(\.inputsFileName)),
            ("kernelEnvironmentFileName", all.map(\.kernelEnvironmentFileName)),
            ("jupyterLiteKernelName", all.map(\.jupyterLiteKernelName)),
            ("jupyterLiteKernelDisplayName", all.map(\.jupyterLiteKernelDisplayName)),
            ("interpreterProbe.command", all.map(\.interpreterProbe.command)),
        ]
        for (field, values) in unique {
            #expect(
                Set(values).count == values.count,
                """
                Two languages share a \(field): \(values). That is the signature of a descriptor \
                literal copied from another language and not fully edited — and it fails silently, \
                by routing one language's work to the other.
                """)
        }
        // Script extensions and kernel aliases are sets, so they are checked for
        // overlap rather than equality.
        var seenExtension: [String: AssignmentLanguage] = [:]
        for language in AssignmentLanguage.allCases {
            for ext in language.descriptor.scriptExtensions {
                #expect(seenExtension[ext] == nil, "\(ext) claimed by two languages")
                seenExtension[ext] = language
            }
        }
    }

    /// The descriptor is the ONLY source for these, so the forwarding
    /// properties must actually forward. A stale copy left behind on the enum
    /// would compile and quietly win at every call site.
    @Test(arguments: AssignmentLanguage.allCases)
    func theEnumPropertiesForwardToTheDescriptor(_ language: AssignmentLanguage) {
        let d = language.descriptor
        #expect(language.displayName == d.displayName)
        #expect(language.scriptExtensions == d.scriptExtensions)
        #expect(language.generatedScriptExtension == d.generatedScriptExtension)
        #expect(language.inputsFileName == d.inputsFileName)
        #expect(language.notebookKernelNames == d.notebookKernelNames)
        #expect(language.kernelEnvironmentFileName == d.kernelEnvironmentFileName)
        #expect(
            language.missingDependencyFailureDescription == d.missingDependencyFailureDescription)
        #expect(language.interpreterProbe.command == d.interpreterProbe.command)
        #expect(language.interpreterProbe.versionArguments == d.interpreterProbe.versionArguments)
    }

    /// The kernel aliases come from the `<lang>KernelNames` statics, not from
    /// inlined literals — `scripts/generate-js-constants.sh` parses those
    /// declarations out of the Swift source to write the browser's copy, so
    /// inlining them here would leave the generator with nothing to find and the
    /// browser routing that language's notebooks to Python.
    @Test func kernelAliasesStillComeFromTheParsedStatics() {
        #expect(AssignmentLanguage.r.descriptor.notebookKernelNames == AssignmentLanguage.rKernelNames)
        #expect(
            AssignmentLanguage.lua.descriptor.notebookKernelNames == AssignmentLanguage.luaKernelNames)
        #expect(AssignmentLanguage.python.descriptor.notebookKernelNames.isEmpty)
    }

    /// `capabilityName` is deliberately NOT a descriptor field: it is the token
    /// an assignment's required-languages list is matched against, and it must
    /// be incapable of drifting from the wire value. A field could drift.
    @Test(arguments: AssignmentLanguage.allCases)
    func capabilityNameIsTheWireValueAndNotADescriptorField(_ language: AssignmentLanguage) {
        #expect(language.capabilityName == language.rawValue)
    }

    // MARK: - The three derived from one judgement + one fact

    /// The derivation reproduces what the three hand-written switches said,
    /// with one deliberate exception asserted below. This is the evidence that
    /// collapsing them changed nothing by accident.
    @Test func theDerivationsMatchTheHandWrittenAnswers() {
        #expect(
            AssignmentLanguage.python.runnerProvidedModules
                == ["test_runtime", "sitecustomize", "_ck_inputs"])
        #expect(AssignmentLanguage.r.runnerProvidedModules.isEmpty)
        #expect(AssignmentLanguage.lua.runnerProvidedModules == ["test_runtime", "_ck_inputs"])

        #expect(AssignmentLanguage.python.supportFilesPathEnvironmentVariable == "PYTHONPATH")
        #expect(AssignmentLanguage.r.supportFilesPathEnvironmentVariable == nil)
        // Lua resolves by name and HAS a variable, but `./?.lua` is already on
        // `package.path` — so the fact, not the mechanism, makes this nil.
        #expect(AssignmentLanguage.lua.supportFilesPathEnvironmentVariable == nil)

        #expect(AssignmentLanguage.r.studentModulePrefixes.isEmpty)
    }

    /// The one deliberate change: Python's hand-written prefix list omitted
    /// `solution` and `submission`, while `test_runtime.py` itself special-cases
    /// `solution.py` — so a hand-authored `import solution` in a browser-graded
    /// test was reported unsatisfiable. Deriving from one shared list fixes it,
    /// and can only ever WIDEN what the guard accepts, which is the direction
    /// that guard resolves ambiguity by design.
    @Test func everyNameAddressableLanguageAcceptsTheNamesTheRunnerCanWrite() {
        for language in AssignmentLanguage.allCases {
            guard case .byName = language.descriptor.moduleResolution else { continue }
            for produced in ["solution", "submission", "student", "_ck_inputs"] {
                #expect(
                    language.studentModulePrefixes.contains(where: { produced.hasPrefix($0) })
                        || language.runnerProvidedModules.contains(produced),
                    """
                    \(language) would reject `\(produced)`, which the runner can genuinely write                     into a grading workspace — the import guard would report an instructor's                     hand-authored reference to it as unsatisfiable.
                    """)
            }
        }
    }

    /// A `fileRead` language declares nothing importable, and that is a fact
    /// rather than an omission: there is no name to resolve, so no guard could
    /// reject anything. Pinned so a future language cannot copy R's empties
    /// while actually loading modules by name — the exact mistake this
    /// derivation removes the opportunity for.
    @Test(arguments: AssignmentLanguage.allCases)
    func onlyFileReadLanguagesDeclareNothingImportable(_ language: AssignmentLanguage) {
        switch language.descriptor.moduleResolution {
        case .fileRead:
            #expect(language.runnerProvidedModules.isEmpty)
            #expect(language.studentModulePrefixes.isEmpty)
            #expect(language.supportFilesPathEnvironmentVariable == nil)
        case .byName:
            #expect(!language.runnerProvidedModules.isEmpty)
            #expect(!language.studentModulePrefixes.isEmpty)
        }
    }
}
