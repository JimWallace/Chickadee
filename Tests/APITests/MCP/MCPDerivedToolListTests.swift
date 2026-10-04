// Tests/APITests/MCP/MCPDerivedToolListTests.swift
//
// Two tool descriptions listed their enum's cases by hand, and both lists were
// short (#1935): `author_script` named seven of the ten pattern kinds, and
// `get_health_alerts` named six of the nine health rules while its own body
// reports all of them. Both lists are now derived. These tests check every
// case, so a new kind, check or rule cannot be left out again.

import Core
import Testing

@testable import APIServer

@Suite struct MCPDerivedToolListTests {

    @Test(arguments: PatternKind.allCases)
    func authorScriptNamesEveryPatternKind(kind: PatternKind) {
        #expect(AuthorScriptTool.description.contains(kind.rawValue))
    }

    @Test(arguments: NotebookCheckKind.allCases)
    func authorScriptNamesEveryNotebookCheckKind(kind: NotebookCheckKind) {
        #expect(AuthorScriptTool.description.contains(kind.rawValue))
    }

    @Test(arguments: HealthRule.allCases)
    func getHealthAlertsNamesEveryRule(rule: HealthRule) {
        #expect(
            GetHealthAlertsTool.description.lowercased().contains(rule.humanReadable.lowercased()))
    }

    /// Mid-sentence, an ordinary first word is lower case, and a name keeps its
    /// capital.
    @Test func ruleLabelsReadMidSentence() {
        let list = GetHealthAlertsTool.ruleList
        #expect(list.contains("runner offline"))
        #expect(!list.contains("Runner offline"))
        #expect(list.contains("BrightSpace grade sync failing"))
    }
}
