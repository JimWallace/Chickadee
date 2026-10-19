// Core/NotebookDefinitionScan.swift
//
// The names a notebook defines, with the cell that defines each one, and its
// `## ` section headings with their cells. `NotebookTestAnchoring` reads it to
// link a suite item to a cell by NAME, so one anchor resolves in the starter,
// the solution and a student's working copy, whatever the cell positions.
//
// Functions come from `scanNotebookForSectionsAndFunctions`, so the two scans
// agree on what a function is. Variables come from the language's
// `VariableScanSyntax`. Like the function scan, a language that cannot be read
// answers "unsupported", never "found nothing".

public import Foundation

/// One name a notebook defines at the top level of a code cell.
public struct NotebookDefinition: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, Codable {
        case function
        case variable
    }

    public let name: String
    public let kind: Kind
    /// The index of the defining cell in the notebook's `cells` array.
    public let cellIndex: Int

    public init(name: String, kind: Kind, cellIndex: Int) {
        self.name = name
        self.kind = kind
        self.cellIndex = cellIndex
    }
}

/// One `## ` heading and the markdown cell that holds it.
public struct NotebookSectionHeading: Sendable, Equatable {
    public let name: String
    public let cellIndex: Int

    public init(name: String, cellIndex: Int) {
        self.name = name
        self.cellIndex = cellIndex
    }
}

public struct NotebookDefinitionScan: Sendable, Equatable {
    /// Every definition in notebook order. A name defined twice appears twice.
    public let definitions: [NotebookDefinition]
    /// Every `## ` heading in notebook order, including a repeated name.
    public let sections: [NotebookSectionHeading]
    /// The indices of the code cells, in order.
    public let codeCellIndices: [Int]
    /// Non-nil when the language's definitions cannot be read. The sections
    /// and code cells are still read, because they do not depend on it.
    public let unsupportedReason: String?

    public init(
        definitions: [NotebookDefinition],
        sections: [NotebookSectionHeading],
        codeCellIndices: [Int],
        unsupportedReason: String? = nil
    ) {
        self.definitions = definitions
        self.sections = sections
        self.codeCellIndices = codeCellIndices
        self.unsupportedReason = unsupportedReason
    }

    /// The definition that wins at run time: the last one, as the function
    /// scan marks earlier ones shadowed.
    public func definition(of name: String) -> NotebookDefinition? {
        definitions.last { $0.name == name }
    }

    /// Each defined name once, in the order of its first definition.
    public var namesInOrder: [String] {
        var seen: Set<String> = []
        return definitions.compactMap { seen.insert($0.name).inserted ? $0.name : nil }
    }

    /// The first code cell after the first `## ` heading named `section`.
    public func firstCodeCell(inSection section: String) -> Int? {
        guard let heading = sections.first(where: { $0.name == section }) else { return nil }
        return codeCellIndices.first { $0 > heading.cellIndex }
    }
}

/// Scans `notebookData` for the names it defines, in `language`.
public func scanNotebookDefinitions(
    _ notebookData: Data, language: AssignmentLanguage?
) -> NotebookDefinitionScan {
    guard let cells = NotebookCellSources.cells(from: notebookData) else {
        return NotebookDefinitionScan(definitions: [], sections: [], codeCellIndices: [])
    }
    var sections: [NotebookSectionHeading] = []
    var codeCells: [(index: Int, source: String)] = []
    for (index, cell) in cells.enumerated() {
        let source = NotebookCellSources.cellSource(cell)
        switch cell["cell_type"] as? String {
        case "markdown":
            if let title = firstSectionHeading(in: source) {
                sections.append(NotebookSectionHeading(name: title, cellIndex: index))
            }
        case "code":
            codeCells.append((index, source))
        default:
            break
        }
    }
    let codeCellIndices = codeCells.map(\.index)

    let functionScan = scanNotebookForSectionsAndFunctions(notebookData, language: language)
    guard let language, functionScan.unsupportedReason == nil,
        case .assignmentPattern(let pattern) = language.descriptor.variableScan,
        let assignment = try? Regex(pattern)
    else {
        return NotebookDefinitionScan(
            definitions: [], sections: sections, codeCellIndices: codeCellIndices,
            unsupportedReason: functionScan.unsupportedReason
                ?? notebookFunctionScanSupport(for: language).unsupportedReason
                ?? "The variable scan cannot read this language.")
    }

    var definitions: [NotebookDefinition] = functionScan.functions.compactMap { entry in
        entry.cellIndex.map { NotebookDefinition(name: entry.info.name, kind: .function, cellIndex: $0) }
    }
    let functionNames = Set(definitions.map(\.name))
    for cell in codeCells {
        for line in cell.source.components(separatedBy: "\n") {
            guard let match = line.firstMatch(of: assignment), match.output.count > 1,
                let captured = match.output[1].substring
            else { continue }
            let name = String(captured)
            // A function written as an assignment (R, Lua) is already a
            // function; a private name is not an anchor, like a private
            // function.
            guard !functionNames.contains(name), !name.hasPrefix("_") else { continue }
            definitions.append(NotebookDefinition(name: name, kind: .variable, cellIndex: cell.index))
        }
    }
    definitions.sort { $0.cellIndex < $1.cellIndex }
    return NotebookDefinitionScan(
        definitions: definitions, sections: sections, codeCellIndices: codeCellIndices)
}
