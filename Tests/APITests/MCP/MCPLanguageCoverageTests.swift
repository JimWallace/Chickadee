// Drift guards for how the assignment languages appear in the AGENT-FACING
// surface: the `initialize` instructions and every tool's description and
// schema.
//
// WHY THESE EXIST, AND WHY THEY ARE NOT THE ONES IN
// `MCPInstructionsCatalogSyncTests`. Those guards pin the INSTRUCTIONS, and
// they worked — the instructions were correct when Racket shipped. The tool
// descriptions were not: five of them still enumerated languages by hand and
// stopped at `cpp`, and four still called personalization expressions "Python
// source", which is the exact defect #1288 was opened to fix one language
// earlier.
//
// So the lesson these encode is the one that round taught: a guard scoped to
// the string someone was looking at does not protect the class. Everything
// below is scoped to the WHOLE served catalog, and derives its expectations
// from `AssignmentLanguage.allCases`, so a seventh language fails them without
// anyone thinking to come here.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPLanguageCoverageTests {

    /// Every piece of text an agent can actually read: the server instructions,
    /// plus each tool's name, description, and both schemas rendered as JSON.
    ///
    /// Schemas are included deliberately — the `cpp`-truncated list in
    /// `get_assignment` lived in a description, but field `description`s inside
    /// a schema are just as agent-facing and just as hand-written.
    private static let servedText: String = {
        var parts = [MCPServerInstructions.text]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for tool in MCPToolCatalog.live.all {
            parts.append(tool.name)
            parts.append(tool.description)
            for schema in [tool.inputSchema, tool.outputSchema] {
                guard let schema,
                    let data = try? encoder.encode(schema),
                    let json = String(data: data, encoding: .utf8)
                else { continue }
                parts.append(json)
            }
        }
        return parts.joined(separator: "\n")
    }()

    // MARK: - No truncated language list survives anywhere

    /// THE guard this whole change exists to install.
    ///
    /// Every historical instance of this bug has the same shape: a list written
    /// when there were N languages, still listing N when there are N+1. So the
    /// stale forms are exactly the PROPER PREFIXES of today's derived lists,
    /// and they are computable — no judgement, no maintenance, and a seventh
    /// language turns every list that stops at six into a named failure here.
    ///
    /// Checked in all three renderings, because the real defect appeared in all
    /// three: `"python, r, lua, octave or cpp"` (set_assignment_language's
    /// prose), `"\"python\" | ... | \"cpp\""` (get_assignment's description),
    /// and the display-name form the instructions use.
    @Test func noProperPrefixOfALanguageListSurvivesInTheServedCatalog() {
        // Scan with the CORRECT renderings removed first. The union form
        // (`"python" | "r" | …`) has no terminal connector, so it literally
        // contains each of its own prefixes — without this, a correctly derived
        // list fails the guard meant to catch a hand-typed one. Deleting the
        // full renderings leaves exactly the remnants that are not derived.
        var scanned = Self.servedText
        for rendering in [
            MCPLanguageProse.displayNames,
            MCPLanguageProse.tokens,
            MCPLanguageProse.quotedTokenAlternatives,
        ] {
            scanned = scanned.replacingOccurrences(of: rendering, with: "«derived»")
        }
        for stale in Self.staleLanguageLists() {
            #expect(
                !scanned.contains(stale),
                """
                The served MCP catalog contains "\(stale)" — a language list that stops short of \
                \(AssignmentLanguage.allCases.count) languages. That is a hand-typed list going \
                stale, which has now happened twice (#1288, then again for Racket). Interpolate \
                the derived rendering from `MCPLanguageProse` instead of typing the names.
                """)
        }
    }

    /// Every proper prefix of `allCases`, rendered all three ways. With six
    /// languages that is fifteen distinctive strings; each is long and specific
    /// enough that a false positive is not a realistic worry.
    private static func staleLanguageLists() -> [String] {
        let cases = AssignmentLanguage.allCases
        guard cases.count > 1 else { return [] }
        var stale: [String] = []
        for count in 1..<cases.count {
            let prefix = Array(cases.prefix(count))
            stale.append(prose(prefix.map(\.displayName)))
            stale.append(prose(prefix.map(\.rawValue)))
            stale.append(prefix.map { "\"\($0.rawValue)\"" }.joined(separator: " | "))
        }
        // A single-language "list" is just that language's name and appears all
        // over legitimate prose ("a cpp assignment must be uploadOnly"). Only
        // multi-item prefixes are evidence of a list.
        return stale.filter { $0.contains(",") || $0.contains(" | ") || $0.contains(" or ") }
    }

    private static func prose(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " or " + last
    }

    /// The complement: the derived renderings are actually REACHING the
    /// catalog. Without this, deleting every list would pass the guard above.
    @Test func everyDerivedLanguageRenderingIsInterpolatedSomewhere() {
        for (label, rendering) in [
            ("displayNames", MCPLanguageProse.displayNames),
            ("tokens", MCPLanguageProse.tokens),
            ("quotedTokenAlternatives", MCPLanguageProse.quotedTokenAlternatives),
        ] {
            #expect(
                Self.servedText.contains(rendering),
                """
                No served text contains MCPLanguageProse.\(label) ("\(rendering)") verbatim, so \
                either it is unused or a hand-typed list replaced it at its call site.
                """)
        }
    }

    // MARK: - A predicate-defined SUBSET is never named short either

    /// The blind spot the guard above documents and accepts.
    ///
    /// `staleLanguageLists()` filters single-language "lists" out on purpose,
    /// because "a cpp assignment must be uploadOnly" is legitimate prose and
    /// not a stale enumeration. It was legitimate right up until Racket became
    /// the second upload-only language, at which point that exact sentence —
    /// in four tool descriptions and the instructions — was a one-item list
    /// that should have had two, and nothing here could see it. The enforcement
    /// predicate (`requiresUploadOnlySubmission`) had picked Racket up
    /// immediately, because it asks `editorSupport` rather than naming C++.
    ///
    /// So this guard is scoped to a SENTENCE rather than to the catalog: any
    /// sentence about upload-only that names one upload-only language must name
    /// all of them. Sentence-scoped because the catalog as a whole legitimately
    /// mentions each language alone in a dozen unrelated places.
    @Test func noSentenceNamesSomeUploadOnlyLanguagesButNotOthers() {
        let uploadOnly = AssignmentLanguage.allCases.filter(requiresUploadOnlySubmission)
        // A one-language answer makes the guard vacuous rather than wrong —
        // there is no subset to get wrong. It starts biting at two, which is
        // where the defect appeared.
        guard uploadOnly.count > 1 else { return }
        for sentence in Self.sentences(of: Self.servedText) {
            let lowered = sentence.lowercased()
            guard lowered.contains("uploadonly") || lowered.contains("upload-only") else { continue }
            let named = uploadOnly.filter {
                lowered.contains($0.rawValue.lowercased())
                    || lowered.contains($0.displayName.lowercased())
            }
            guard !named.isEmpty, named.count < uploadOnly.count else { continue }
            let missing = uploadOnly.filter { !named.contains($0) }
            Issue.record(
                """
                A served MCP sentence about upload-only names \
                \(named.map(\.displayName).joined(separator: ", ")) but not \
                \(missing.map(\.displayName).joined(separator: ", ")), which \
                `requiresUploadOnlySubmission` treats identically. Interpolate \
                `LanguageProse.uploadOnlyTokens` / `.uploadOnlyDisplayNames` instead of naming a \
                language. Sentence: "\(sentence.trimmingCharacters(in: .whitespacesAndNewlines))"
                """)
        }
    }

    /// Split on sentence-ending punctuation. Crude on purpose: a false split
    /// can only make the guard check a shorter span, never invent a failure,
    /// and JSON-encoded schema text has no reliable sentence structure anyway.
    private static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == "." || $0 == "\n" }).map(String.init)
    }

    // MARK: - Expressions are never described as Python

    /// The specific regression #1288 named, generalized from the instructions
    /// (where it was already guarded) to the tool descriptions (where it was
    /// not, and where it had survived).
    ///
    /// A personalization expression is written in the ASSIGNMENT'S language and
    /// evaluated by that language's interpreter. Telling an agent otherwise
    /// makes it write something that fails with a syntax error on five of six
    /// languages.
    @Test func personalizationIsNeverDescribedAsPython() {
        for phrase in [
            "Python source", "Python expression", "Python literal", "Python expressions",
            "Python-literal",
        ] {
            #expect(
                !Self.servedText.contains(phrase),
                """
                The served MCP catalog says "\(phrase)". Personalization expressions and the \
                literals they resolve to are in the ASSIGNMENT'S own language — describing them as \
                Python tells an agent on an R, Lua, Octave, C++ or Racket assignment to write \
                something that cannot run. Say "the assignment's own language".
                """)
        }
    }

    // MARK: - The capability payload

    @Test func capabilityPayloadCoversEveryLanguage() throws {
        let payload = MCPLanguageCapability.all
        #expect(payload.count == AssignmentLanguage.allCases.count)
        for language in AssignmentLanguage.allCases {
            let entry = try #require(
                payload.first { $0.name == language.rawValue },
                "get_server_info reports no capabilities for \(language.displayName)")
            #expect(entry.displayName == language.displayName)
            #expect(entry.generatedScriptExtension == language.generatedScriptExtension)
            #expect(!entry.scriptExtensions.isEmpty)
            #expect(!entry.personalizationInterpreter.isEmpty)
        }
    }

    /// The property that makes the payload worth having over prose: what an
    /// agent is TOLD is available and what it is ALLOWED to save come from the
    /// same predicate, so they cannot drift apart.
    @Test func reportedCheckKindsAgreeWithTheSaveTimeRefusal() {
        for language in AssignmentLanguage.allCases {
            let entry = MCPLanguageCapability(language)
            for kind in NotebookCheckKind.allCases {
                let supported = notebookCheckKindIsSupported(kind, language: language)
                #expect(
                    entry.supportedNotebookCheckKinds.contains(kind.rawValue) == supported,
                    """
                    get_server_info reports \(kind.rawValue) as \
                    \(supported ? "unsupported" : "supported") for \(language.displayName), but \
                    the save-time predicate disagrees. An agent told one thing and refused the \
                    other has no way to proceed.
                    """)
                #expect(
                    (entry.unsupportedNotebookCheckKinds[kind.rawValue] != nil) == !supported,
                    "\(language.displayName)/\(kind.rawValue): exclusion reason and support disagree"
                )
            }
        }
    }

    /// Every refusal carries a reason. A kind listed as unavailable with an
    /// empty explanation is barely better than the rejection-message-only state
    /// this replaced.
    @Test func everyExclusionExplainsItself() {
        for entry in MCPLanguageCapability.all {
            for (kind, reason) in entry.unsupportedNotebookCheckKinds {
                #expect(
                    reason.count > 10,
                    "\(entry.name)/\(kind) is excluded with no usable reason: \"\(reason)\"")
            }
        }
    }

    /// The upload-only languages are reported as such, and are exactly the ones
    /// with no editor kernel. Derived from `EditorSupport`, so this pins the
    /// projection rather than the current membership.
    @Test func uploadOnlyLanguagesReportNoEditorKernel() {
        for language in AssignmentLanguage.allCases {
            let entry = MCPLanguageCapability(language)
            switch language.editorSupport {
            case .uploadOnly:
                #expect(entry.submissionMode == SubmissionMode.uploadOnly.rawValue)
                #expect(entry.editorKernel == nil)
                // No notebook exists to inspect, so no check kind can apply.
                #expect(entry.supportedNotebookCheckKinds.isEmpty)
            case .notebookKernel(_, let kernelName, _, _, _):
                #expect(entry.submissionMode == SubmissionMode.notebook.rawValue)
                #expect(entry.editorKernel == kernelName)
            }
        }
    }

    /// `get_server_info` advertises the field, so a client validating
    /// `structuredContent` against the declared schema does not reject it.
    @Test func serverInfoSchemaDeclaresLanguages() throws {
        guard case .object(let schema) = try #require(GetServerInfoTool.outputSchema),
            case .object(let properties) = try #require(schema["properties"])
        else {
            Issue.record("get_server_info outputSchema is not an object with properties")
            return
        }
        #expect(properties["languages"] != nil, "get_server_info does not declare `languages`")
        guard case .array(let required) = try #require(schema["required"]) else { return }
        #expect(required.contains(.string("languages")))
    }
}
