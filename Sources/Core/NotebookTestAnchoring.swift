// Core/NotebookTestAnchoring.swift
//
// Links each suite item to the notebook cell it tests (notebook views brief,
// NB3). The student guide and the instructor suite payload both use it.
//
// It links by NAME, not by cell position: an anchor is a name that a cell
// defines, or a `## ` section, so the same anchor resolves in the starter, the
// solution and a student's working copy. Resolution, first rule that applies:
//
//   1. Pinned: the item's stored anchor override.
//   2. Notebook check: the function or variable name the check already names.
//   3. Pattern family: the target function, or the variable a
//      variable-equality case reads.
//   4. Script test: the identifiers in its source that the solution defines.
//      One match is that name. Several match: the first in the notebook, and
//      `ambiguous`. None falls through.
//   5. Section: the item's suite section, by its `## ` heading.
//   6. Otherwise unlinked.
//
// Grading never reads an anchor.

import Foundation

/// What a suite item is linked to, independent of any one notebook.
public struct NotebookAnchor: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Equatable, Codable {
        /// A name a code cell defines.
        case name
        /// The first code cell of a `## ` section.
        case section
        /// Nothing: shown as "Not linked to a cell".
        case unlinked
    }

    /// Which resolution rule produced the anchor.
    public enum Rule: String, Sendable, Equatable, Codable {
        case pinned
        case check
        case family
        case script
        case section
    }

    public let kind: Kind
    /// The defined name, or the section heading. Nil when unlinked.
    public let name: String?
    public let rule: Rule?
    /// True when a script test names more than one defined name.
    public let ambiguous: Bool

    public init(kind: Kind, name: String?, rule: Rule?, ambiguous: Bool = false) {
        self.kind = kind
        self.name = name
        self.rule = rule
        self.ambiguous = ambiguous
    }

    public static let unlinked = NotebookAnchor(kind: .unlinked, name: nil, rule: nil)

    /// The cell this anchor points at in `notebook`, or nil when the notebook
    /// does not define the name (a student renamed the function) or has no
    /// such heading.
    public func cellIndex(in notebook: NotebookDefinitionScan) -> Int? {
        guard let name else { return nil }
        switch kind {
        case .name: return notebook.definition(of: name)?.cellIndex
        case .section: return notebook.firstCodeCell(inSection: name)
        case .unlinked: return nil
        }
    }
}

/// What the resolver knows about one suite item.
public struct NotebookAnchorRequest: Sendable, Equatable {
    /// The stored override (rule 1).
    public var pinned: String?
    /// The name a notebook check or a pattern family targets (rules 2 and 3).
    public var target: String?
    /// Which of rules 2 and 3 `target` comes from.
    public var targetRule: NotebookAnchor.Rule?
    /// The source of a hand-written script test (rule 4).
    public var scriptSource: String?
    /// The name of the item's suite section (rule 5).
    public var sectionName: String?

    public init(
        pinned: String? = nil, target: String? = nil, targetRule: NotebookAnchor.Rule? = nil,
        scriptSource: String? = nil, sectionName: String? = nil
    ) {
        self.pinned = pinned
        self.target = target
        self.targetRule = targetRule
        self.scriptSource = scriptSource
        self.sectionName = sectionName
    }
}

public enum NotebookTestAnchoring {

    /// The request for `entry`, from the manifest that holds it.
    ///
    /// - Parameters:
    ///   - scriptSource: the entry's script, for a hand-written test. Nil when
    ///     it could not be read, which skips rule 4.
    ///   - pinned: an anchor override. When nil, the entry's own stored
    ///     `anchor` is used.
    public static func request(
        for entry: TestSuiteEntry, in manifest: TestProperties,
        scriptSource: String? = nil, pinned: String? = nil
    ) -> NotebookAnchorRequest {
        // A pin passed in wins over the entry's own stored pin.
        var request = NotebookAnchorRequest(pinned: nonEmpty(pinned) ?? nonEmpty(entry.anchor))
        request.sectionName = entry.sectionID.flatMap { id in manifest.sections.first { $0.id == id }?.name }
        if let checkID = entry.generatedByCheck {
            if let check = manifest.notebookChecks.first(where: { $0.id == checkID }) {
                request.target = checkTarget(check)
                request.targetRule = request.target == nil ? nil : .check
            }
        } else if let familyID = entry.generatedBy {
            if let family = manifest.patternFamilies.first(where: { $0.id == familyID }) {
                request.target = familyTarget(family, script: entry.script)
                request.targetRule = request.target == nil ? nil : .family
            }
        } else {
            request.scriptSource = scriptSource
        }
        return request
    }

    /// Resolves `request`. `solution` decides rule 4, because a script test is
    /// written against the solution's names.
    public static func resolve(
        _ request: NotebookAnchorRequest, solution: NotebookDefinitionScan
    ) -> NotebookAnchor {
        if let pinned = request.pinned {
            return NotebookAnchor(kind: .name, name: pinned, rule: .pinned)
        }
        if let target = request.target, let rule = request.targetRule {
            return NotebookAnchor(kind: .name, name: target, rule: rule)
        }
        if let source = request.scriptSource {
            let mentioned = identifiers(in: source)
            let matches = solution.namesInOrder.filter(mentioned.contains)
            if let first = matches.first {
                return NotebookAnchor(kind: .name, name: first, rule: .script, ambiguous: matches.count > 1)
            }
        }
        if let section = request.sectionName, solution.sections.contains(where: { $0.name == section }) {
            return NotebookAnchor(kind: .section, name: section, rule: .section)
        }
        return .unlinked
    }

    /// The name a notebook check reads, or nil for a kind that reads no name
    /// (a figure count, a source match), which anchors by section.
    static func checkTarget(_ check: NotebookCheck) -> String? {
        switch check.kind {
        case .functionExists, .variableExists, .dataFrameShape, .dataFrameColumns, .dataFrameEquality,
            .seriesEquality, .numericArrayClose:
            return nonEmpty(check.variable)
        case .figureCount, .cellContains, .astStructure:
            return nil
        }
    }

    /// The name a family's generated `script` targets: its function, or for a
    /// variable-equality family the variable that the script's case reads. A
    /// program-I/O family calls no function and anchors by section.
    static func familyTarget(_ family: PatternFamily, script: String) -> String? {
        switch family.kind {
        case .variableEquality:
            // A generated filename ends `test_<familyID>_<caseKey>.<ext>`.
            let stem = script.lastIndex(of: ".").map { String(script[..<$0]) } ?? script
            let matching = family.cases.first { stem.hasSuffix("test_\(family.id)_\($0.key)") }
            guard case .string(let variable)? = matching?.args.first else { return nil }
            return nonEmpty(variable)
        case .programIO:
            return nil
        default:
            return nonEmpty(family.functionName)
        }
    }

    /// Every identifier-shaped token in `source`, and each dotted part of it,
    /// so `student_module.count_days` yields `count_days` and an R name
    /// `mean.steps` survives whole.
    static func identifiers(in source: String) -> Set<String> {
        var result: Set<String> = []
        for match in source.matches(of: /[A-Za-z_.][A-Za-z0-9_.]*/) {
            let token = String(match.output)
            result.insert(token)
            for part in token.split(separator: ".") { result.insert(String(part)) }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }
}
