// Tests/APITests/RecordDimensionCoverageTests.swift
//
// Every surface that lists a record's ranking dimension derives from
// `RecordDimension.allCases` through `RecordDimensionPresentation`. Before
// `highestMetric`, the "Ranked by" select, the JS summary table and the MCP
// schema enum were three hand-typed copies of four cases — the exact shape
// `MCPLanguageCoverageTests` exists for, one enum over.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct RecordDimensionCoverageTests {

    @Test func everyDimensionHasADistinctOption() {
        let options = RecordDimensionPresentation.all
        #expect(options.count == RecordDimension.allCases.count)
        #expect(Set(options.map(\.value)).count == options.count)
        #expect(Set(options.map(\.label)).count == options.count)
        for option in options {
            #expect(RecordDimension(rawValue: option.value) != nil)
            #expect(!option.label.isEmpty)
            #expect(!option.detail.isEmpty)
            // Chrome, not prose: a select label is a two-or-three-word phrase.
            #expect(option.label.split(separator: " ").count <= 3, "\(option.label)")
        }
    }

    /// The MCP `recordDimension` enum is the whole enum, and its description
    /// names every case.
    @Test func mcpSchemaEnumeratesEveryDimension() throws {
        guard case .object(let schema) = achievementRowSchema,
            case .object(let properties)? = schema["properties"],
            case .object(let dimension)? = properties["recordDimension"],
            case .array(let values)? = dimension["enum"],
            case .string(let description)? = dimension["description"]
        else {
            Issue.record("get_achievements row schema lost its recordDimension enum")
            return
        }
        #expect(values == RecordDimension.allCases.map { .string($0.rawValue) })
        for dimension in RecordDimension.allCases {
            #expect(description.contains(dimension.rawValue), "description omits \(dimension.rawValue)")
        }
    }

    /// The editor template renders the select from the context, and the JS
    /// reads labels off that select — neither holds a dimension name.
    @Test func editorAndJSHoldNoHandTypedDimensionList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let template = try String(
            contentsOf: root.appendingPathComponent("Resources/Views/_assignment-edit-body.leaf"),
            encoding: .utf8)
        let js = try String(
            contentsOf: root.appendingPathComponent("Public/achievements-editor.js"), encoding: .utf8)
        #expect(template.contains("#for(dim in recordDimensionOptions)"))
        for dimension in RecordDimension.allCases {
            #expect(
                !template.contains("value=\"\(dimension.rawValue)\""),
                "the edit template hand-types the \(dimension.rawValue) option")
            #expect(
                !js.contains("\(dimension.rawValue):"),
                "achievements-editor.js hand-types a \(dimension.rawValue) label")
        }
    }
}
