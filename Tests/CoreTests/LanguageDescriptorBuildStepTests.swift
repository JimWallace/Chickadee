import Testing

@testable import Core

// The two build-related descriptor facts answer different questions, and the
// custom-script scaffold conflating them is how Java landed in the interpreted
// branch (#1394). These pin the answers per language and the one implication
// between them, so a copied literal cannot quietly give a compiled language
// the interpreted shape.
@Suite struct LanguageDescriptorBuildStepTests {

    /// The languages that build before they run, pinned by name. Both compile;
    /// only C++ produces something the kernel execs.
    @Test func theCompiledLanguagesArePinned() {
        let compiled = AssignmentLanguage.allCases.filter {
            $0.descriptor.gradingCompilesBeforeRunning
        }
        #expect(
            compiled == [.cpp, .java],
            """
            The compile-before-run set changed: \(compiled). A new compiled \
            language is a scaffold decision — update this pin in the same change.
            """)
    }

    /// Exec'ing a produced binary implies producing one, so the exec fact can
    /// never be true where the compile fact is false. The converse is Java,
    /// and is exactly the case the scaffold used to get wrong.
    @Test(arguments: AssignmentLanguage.allCases)
    func execRequiresACompileStep(_ language: AssignmentLanguage) {
        let d = language.descriptor
        if d.capabilityRequiresExecutableOutput {
            #expect(d.gradingCompilesBeforeRunning)
        }
    }

    @Test func javaCompilesWithoutProducingAnExecutable() {
        let d = AssignmentLanguage.java.descriptor
        #expect(d.gradingCompilesBeforeRunning)
        #expect(!d.capabilityRequiresExecutableOutput)
    }

    /// For a compiled language the probe IS the compiler — the capability a
    /// host can genuinely lack — so the scaffold can name it without a table.
    @Test(arguments: AssignmentLanguage.allCases)
    func aCompiledLanguageProbesItsCompiler(_ language: AssignmentLanguage) {
        let d = language.descriptor
        guard d.gradingCompilesBeforeRunning else { return }
        #expect(!d.interpreterProbe.command.isEmpty)
        if !d.capabilityRequiresExecutableOutput {
            // A runtime distinct from the compiler is what runs the artefacts.
            #expect(d.scriptRunCommand != d.interpreterProbe.command)
        }
    }
}
