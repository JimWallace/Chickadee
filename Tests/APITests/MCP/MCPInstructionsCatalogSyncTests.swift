// Drift guards for the agent-facing copy of the MCP server.  The server-level
// instructions (`MCPServerInstructions.text`, returned from `initialize`) and
// each tool's description/schema/annotations are maintained by hand and must
// stay in sync with the live catalog (`MCPToolCatalog.live`).  These tests
// turn that convention into a build failure: adding a tool without teaching
// the instructions about it — or dropping its output schema or annotations —
// fails here instead of silently degrading what connected agents see.

import Core
import Testing

@testable import APIServer

@Suite struct MCPInstructionsCatalogSyncTests {
    private let tools = MCPToolCatalog.live.all
    private let instructions = MCPServerInstructions.text

    @Test func catalogHasUniqueSnakeCaseNames() {
        // A wholesale catalog regression (e.g. an empty registry from a bad
        // merge) should fail loudly, not pass the per-tool loops vacuously.
        #expect(tools.count >= 30)
        #expect(Set(tools.map(\.name)).count == tools.count)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz_")
        for tool in tools {
            #expect(
                !tool.name.isEmpty && tool.name.allSatisfy { allowed.contains($0) },
                "\(tool.name) is not lower_snake_case")
        }
    }

    @Test func everyCatalogToolIsMentionedInInstructions() {
        for tool in tools {
            #expect(
                instructions.contains(tool.name),
                "MCPServerInstructions.text never mentions \(tool.name) — update the instructions when changing the catalog"
            )
        }
    }

    @Test func everyToolHasDescriptionAndObjectInputSchema() {
        for tool in tools {
            #expect(!tool.description.isEmpty, "\(tool.name) has an empty description")
            guard case .object(let schema) = tool.inputSchema else {
                Issue.record("\(tool.name) inputSchema is not a JSON object")
                continue
            }
            #expect(
                schema["type"] == .string("object"),
                "\(tool.name) inputSchema must declare type:object")
        }
    }

    @Test func everyToolDeclaresAnOutputSchema() {
        // All tools ship an outputSchema today; keep it that way so clients
        // can always validate the structuredContent a tool returns.
        for tool in tools {
            #expect(
                tool.outputSchema != nil,
                "\(tool.name) declares no outputSchema — the structuredContent shape is part of the advertised contract"
            )
        }
    }

    @Test func annotationsAgreeWithRequiredScopes() throws {
        for tool in tools {
            #expect(!tool.requiredScopes.isEmpty, "\(tool.name) requires no scopes")
            let annotations = try #require(
                tool.annotations, "\(tool.name) advertises no annotations")
            let isReadOnly = tool.requiredScopes == [.read]
            #expect(
                annotations.readOnlyHint == isReadOnly,
                "\(tool.name) readOnlyHint must agree with its required scopes")
        }
    }

    // MARK: - The agent-facing copy names every language

    /// The instructions are PROSE. No compiler and no `allCases` test reaches a
    /// string literal, which makes a hand-written language list the one shape
    /// that goes stale silently — and it did: the guide told every connecting
    /// agent that personalization expressions are "Python source" for the whole
    /// of R's and Lua's existence, which is a syntax error on those
    /// assignments. `supportedLanguageNames` derives from `allCases`; this
    /// pins that it is actually interpolated, and that no language is missing.
    @Test func theInstructionsNameEverySupportedLanguage() {
        for language in AssignmentLanguage.allCases {
            #expect(
                instructions.contains(language.displayName),
                """
                The initialize instructions never mention \(language.displayName), so an agent \
                authoring for it is working from a guide that does not know it exists. The \
                language list is derived from allCases in `supportedLanguageNames` — interpolate \
                that rather than typing a list.
                """)
        }
    }

    /// The above is necessary and NOT sufficient: every language's name can
    /// appear incidentally in unrelated prose, so it passes even if the derived
    /// list was replaced by a hand-typed one. Verified by breaking it — swapping
    /// both interpolations for a hardcoded "Python or R" left it green, because
    /// another sentence happened to say "Lua". This pins the property that
    /// actually matters: the DERIVED value is what got interpolated.
    @Test func theDerivedLanguageListIsActuallyInterpolated() {
        #expect(
            instructions.contains(MCPServerInstructions.supportedLanguageNames),
            """
            The instructions do not contain the derived language list \
            (\(MCPServerInstructions.supportedLanguageNames)) verbatim, which means a hand-typed \
            list replaced it. That list is prose — no compiler reaches it — so a hand-typed one is \
            the shape that goes stale silently the next time a language is added.
            """)
    }

    /// The specific regression: expressions must not be described as Python.
    @Test func expressionsAreNotDescribedAsPythonOnly() {
        #expect(
            !instructions.contains("expressions` (a name + Python source"),
            """
            The instructions describe personalization expressions as Python source. They are \
            written in the ASSIGNMENT'S language and evaluated by that language's interpreter, so \
            this tells an agent on an R or Lua assignment to write something that cannot run.
            """)
    }

    /// `supportedLanguageNames` reads as prose, not as a debug dump — it is
    /// interpolated into a sentence an agent reads.
    @Test func theDerivedLanguageListReadsAsProse() {
        let list = MCPServerInstructions.supportedLanguageNames
        #expect(!list.isEmpty)
        #expect(!list.contains("["), "\(list) looks like a collection dump, not prose")
        for language in AssignmentLanguage.allCases {
            #expect(list.contains(language.displayName), "\(list) omits \(language.displayName)")
        }
        if AssignmentLanguage.allCases.count > 1 {
            #expect(list.contains(" or "), "\(list) does not read as a list")
        }
    }
}
