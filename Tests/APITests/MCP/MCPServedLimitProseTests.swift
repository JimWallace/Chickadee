// Tests/APITests/MCP/MCPServedLimitProseTests.swift
//
// The served text states the real support-file download limit, taken from the
// constant the fetcher enforces, and the glossed kind lists use the shared
// list rendering (#2343).

import Core
import Testing

@testable import APIServer

@Suite struct MCPServedLimitProseTests {
    @Test func theDownloadLimitTextFollowsTheConstant() {
        #expect(SupportFileURLFetcher.maxBytesText == "\(SupportFileURLFetcher.maxBytes / (1024 * 1024)) MB")
        #expect(MCPServerInstructions.text.contains("\(SupportFileURLFetcher.maxBytesText) cap"))
        #expect(String(describing: AuthorScriptTool.inputSchema).contains(SupportFileURLFetcher.maxBytesText))
    }

    @Test func theGlossedKindListsEndWithAPlainAnd() {
        for list in [MCPPatternKindProse.glossedList, MCPNotebookCheckKindProse.glossedList] {
            #expect(!list.contains(", and "))
            #expect(list.contains(" and "))
        }
    }

    @Test func theSharedListTakesAConjunction() {
        #expect(LanguageProse.list(["a", "b", "c"]) == "a, b or c")
        #expect(LanguageProse.list(["a", "b", "c"], conjunction: "and") == "a, b and c")
        #expect(LanguageProse.list(["a"], conjunction: "and") == "a")
    }
}
