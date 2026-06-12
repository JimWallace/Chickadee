// Tests/APITests/AuditActionDisplayTests.swift
//
// Guards the /admin/audit display layer: every audit action must map to a
// human-readable category + label (the table no longer shows the raw machine
// identifier alone), and the raw-string resolver must degrade gracefully for a
// historical action no longer present in the enum.

import Testing

@testable import APIServer

@Suite struct AuditActionDisplayTests {

    @Test func everyActionHasNonEmptyCategoryAndLabel() {
        for action in AuditAction.allCases {
            #expect(!action.label.isEmpty, "missing label for \(action.rawValue)")
            #expect(!action.category.rawValue.isEmpty, "missing category for \(action.rawValue)")
        }
    }

    @Test func actionLabelsAreUnique() {
        // A duplicated label would make the action filter dropdown ambiguous.
        let labels = AuditAction.allCases.map(\.label)
        #expect(Set(labels).count == labels.count)
    }

    @Test func rawResolverMapsKnownActions() {
        let resolved = AuditActionDisplay.categoryLabel(forRaw: AuditAction.mcpConsentGranted.rawValue)
        #expect(resolved.category == AuditCategory.mcp.rawValue)
        #expect(resolved.label == "MCP access authorized")
    }

    @Test func rawResolverFallsBackForUnknownActions() {
        let resolved = AuditActionDisplay.categoryLabel(forRaw: "legacy.removed_action")
        #expect(resolved.category == "Other")
        #expect(resolved.label == "legacy.removed_action")
    }
}
