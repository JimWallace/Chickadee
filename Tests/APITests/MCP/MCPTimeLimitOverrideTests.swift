// The per-test time-limit override, parsed and described in one place (#1941).
//
// Seven schema properties carried no bounds, "1–600" was typed into eleven
// descriptions, and the rule that 0 clears the override was coded five times.
// These pin the one parser and check that every override field the catalog
// serves takes its bounds from `mcpTimeLimitRange`.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct MCPTimeLimitOverrideTests {

    @Test func anOmittedOverrideIsUnchanged() throws {
        #expect(try parseTimeLimitOverride(nil, field: "f") == .unchanged)
    }

    @Test func zeroClearsTheOverride() throws {
        #expect(try parseTimeLimitOverride(0, field: "f") == .clear)
    }

    @Test(arguments: [mcpTimeLimitRange.lowerBound, 30, mcpTimeLimitRange.upperBound])
    func aValueInRangeSetsTheOverride(seconds: Int) throws {
        #expect(try parseTimeLimitOverride(seconds, field: "f") == .set(seconds))
    }

    @Test(arguments: [-1, mcpTimeLimitRange.upperBound + 1])
    func aValueOutOfRangeIsRefusedNamingTheField(seconds: Int) {
        #expect {
            try parseTimeLimitOverride(seconds, field: "cases[01].timeLimitSeconds")
        } throws: { error in
            guard case MCPToolError.invalidArguments(let detail) = error else { return false }
            return detail.contains("cases[01].timeLimitSeconds")
                && detail.contains("(got \(seconds))")
        }
    }

    @Test func anEditAppliesToTheStoredOverride() {
        #expect(TimeLimitOverrideEdit.unchanged.applied(to: 45) == 45)
        #expect(TimeLimitOverrideEdit.unchanged.applied(to: nil) == nil)
        #expect(TimeLimitOverrideEdit.clear.applied(to: 45) == nil)
        #expect(TimeLimitOverrideEdit.set(90).applied(to: 45) == 90)
        #expect(TimeLimitOverrideEdit.set(90).applied(to: nil) == 90)
    }

    /// Every `timeLimitSeconds` / `defaultTimeLimitSeconds` property any tool
    /// serves, at any depth of its input schema.
    private static func overrideProperties(in schema: JSONValue, path: String) -> [(String, JSONValue)] {
        var found: [(String, JSONValue)] = []
        switch schema {
        case .object(let members):
            if case .object(let properties)? = members["properties"] {
                for (name, value) in properties
                where name == "timeLimitSeconds" || name == "defaultTimeLimitSeconds" {
                    found.append(("\(path).\(name)", value))
                }
            }
            for (key, value) in members {
                found += overrideProperties(in: value, path: "\(path).\(key)")
            }
        case .array(let items):
            for (index, item) in items.enumerated() {
                found += overrideProperties(in: item, path: "\(path)[\(index)]")
            }
        default:
            break
        }
        return found
    }

    /// Each override field is bounded 0 (clear) to the top of the range, and
    /// states the range as the constant renders it.
    @Test func everyOverrideFieldTakesItsBoundsFromTheConstant() {
        var seen = 0
        for tool in MCPToolCatalog.live.all {
            for (path, property) in Self.overrideProperties(in: tool.inputSchema, path: tool.name) {
                seen += 1
                guard case .object(let members) = property else {
                    Issue.record("\(path) is not a schema object")
                    continue
                }
                #expect(members["minimum"] == .int(0), "\(path) has no lower bound of 0")
                #expect(members["maximum"] == .int(mcpTimeLimitRange.upperBound), "\(path) has the wrong upper bound")
                guard case .string(let description)? = members["description"] else {
                    Issue.record("\(path) has no description")
                    continue
                }
                #expect(description.contains(mcpTimeLimitRangeText), "\(path) does not state the range")
            }
        }
        // author_script, update_suite, author_notebook_check, and both
        // pattern-family tools' default and per-case fields.
        #expect(seen >= 7, "found only \(seen) override fields; the walk is broken")
    }

    /// `set_time_limit` takes the default itself, not an override, so 0 is not
    /// legal there: its lower bound is the range's.
    @Test func setTimeLimitTakesTheRangeItself() {
        guard case .object(let schema) = SetTimeLimitTool.inputSchema,
            case .object(let properties)? = schema["properties"],
            case .object(let seconds)? = properties["seconds"]
        else {
            Issue.record("set_time_limit has no seconds property")
            return
        }
        #expect(seconds["minimum"] == .int(mcpTimeLimitRange.lowerBound))
        #expect(seconds["maximum"] == .int(mcpTimeLimitRange.upperBound))
    }
}
