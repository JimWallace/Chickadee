// APIServer/MCP/Protocol/MCPLanguageCapability.swift
//
// What one assignment language can do, as a value an agent can READ — the
// capability-discovery half of issue #1290.
//
// WHY THIS EXISTS. Before it, no MCP tool reported which languages the server
// has. `get_server_info` returned version / mode / scopes; `get_assignment`
// reported an assignment's language but nothing about what that language
// supports. So an agent could not discover which pattern-family and
// notebook-check kinds are available to it, or that six check kinds are refused
// on Lua and all ten on C++ and Racket. It found out by having a save REJECTED.
//
// That is a poor interface on its own, but the reason it mattered enough to fix
// is second-order: with no machine-readable answer, the guidance had to be
// carried in PROSE — and prose is the surface that goes stale silently. It did,
// twice (see `MCPLanguageProse`). A payload built from `allCases` cannot omit a
// language, and a per-kind answer taken from the save-time predicate cannot
// disagree with the refusal an agent would actually hit.
//
// EVERY FIELD IS DERIVED FROM WHATEVER ALREADY OWNS THE ANSWER. Nothing here is
// tabulated per language: the extensions and kernel facts come off
// `LanguageDescriptor`, the check-kind exclusions off
// `notebookCheckKindUnsupportedReason` (the predicate the save-time refusal
// itself calls), null support off `AuthoringLanguageFacts` (which took it from
// `JSONValue.literal`), and expression support off `PersonalizationEvaluator`.
// If a seventh language needs a NEW fact, add it to whichever type owns it and
// project it here — do not answer it twice.

import Core

/// One language's authoring capabilities, as reported by `get_server_info`.
struct MCPLanguageCapability: Encodable, Sendable, Equatable {

    /// The wire token an agent passes to `set_assignment_language`, and the
    /// value `get_assignment` reports.
    let name: String

    /// How the language is written in prose.
    let displayName: String

    /// Graded-script filename extensions that mark a hand-written script as
    /// this language, sorted for a stable payload.
    let scriptExtensions: [String]

    /// The extension Chickadee's GENERATED tests get. Not always the
    /// language's own: a generated C++ case is a `.sh` wrapper that compiles
    /// and runs a translation unit, which is why this is reported separately
    /// from `sourceFileExtension` rather than inferred from the language.
    let generatedScriptExtension: String

    /// The extension a source file in this language carries — what an
    /// extracted notebook's code becomes, and what `solution.<ext>` is called.
    let sourceFileExtension: String

    /// How students hand work in for this language: "notebook" when a vendored
    /// editor kernel exists, "uploadOnly" when none does.
    ///
    /// Load-bearing for an authoring agent, not decoration: on an uploadOnly
    /// language there is no starter notebook to write `{{placeholder}}`s into
    /// and no submitted notebook for a check to inspect, which is exactly why
    /// every notebook-check kind is refused there.
    let submissionMode: String

    /// The vendored JupyterLite kernel serving this language, or nil when the
    /// language is upload-only.
    let editorKernel: String?

    /// Whether a per-student `=` expression can be evaluated for this language,
    /// and the interpreter that evaluates it.
    ///
    /// The expression LANGUAGE is always the assignment's own — that is the
    /// fact whose prose form went stale twice — so it is not restated as a
    /// separate field. What an agent cannot otherwise know is whether the
    /// server can run one, and with what.
    let personalizationExpressions: Bool
    let personalizationInterpreter: String

    /// Whether a JSON `null` has a rendering in this language. False only for
    /// C++, whose renderer emits a poison identifier so that a leaked null is a
    /// compile error; a C++ family carrying a null is refused at save.
    let supportsNullValues: Bool

    /// Pattern-family kinds this language can render, sorted.
    ///
    /// Every language currently renders all eight — `performanceThreshold` on
    /// C++ is supportable precisely BECAUSE it is native-only — so there is no
    /// per-language predicate to consult and this is `PatternKind.allCases`.
    /// It is reported anyway, and as a derived list rather than a documented
    /// constant, so that a seventh language which refuses one is a change to
    /// this projection and not a silent lie in the payload.
    let supportedPatternKinds: [String]

    /// Notebook-check kinds this language can render, sorted, and the ones it
    /// cannot with the reason for each.
    ///
    /// Both come from `notebookCheckKindUnsupportedReason`, which is the same
    /// predicate `validateKindSupport` refuses a save with — so what an agent
    /// is told here and what it is told when it tries cannot disagree.
    let supportedNotebookCheckKinds: [String]
    let unsupportedNotebookCheckKinds: [String: String]

    init(_ language: AssignmentLanguage) {
        let descriptor = language.descriptor
        self.name = language.rawValue
        self.displayName = descriptor.displayName
        self.scriptExtensions = descriptor.scriptExtensions.sorted()
        self.generatedScriptExtension = descriptor.generatedScriptExtension
        self.sourceFileExtension = descriptor.sourceFileExtension
        switch descriptor.editorSupport {
        case .notebookKernel(_, let kernelName, _, _):
            self.submissionMode = SubmissionMode.notebook.rawValue
            self.editorKernel = kernelName
        case .uploadOnly:
            self.submissionMode = SubmissionMode.uploadOnly.rawValue
            self.editorKernel = nil
        }
        self.personalizationExpressions = PersonalizationEvaluator.supportsEvaluation(language)
        self.personalizationInterpreter = descriptor.interpreterProbe.command
        self.supportsNullValues = AuthoringLanguageFacts(language).nullLiteral != nil
        self.supportedPatternKinds = PatternKind.allCases.map(\.rawValue).sorted()

        var supported: [String] = []
        var unsupported: [String: String] = [:]
        for kind in NotebookCheckKind.allCases {
            if let reason = notebookCheckKindUnsupportedReason(kind, language: language) {
                unsupported[kind.rawValue] = reason
            } else {
                supported.append(kind.rawValue)
            }
        }
        self.supportedNotebookCheckKinds = supported.sorted()
        self.unsupportedNotebookCheckKinds = unsupported
    }

    /// Every language the server has, in `allCases` order.
    ///
    /// The whole point: a seventh language appears here by existing, with no
    /// edit to this file, to `get_server_info`, or to any prose.
    static var all: [MCPLanguageCapability] {
        AssignmentLanguage.allCases.map(MCPLanguageCapability.init)
    }
}
