// Core/DatasetDictionary.swift
//
// The data dictionary of a course library dataset version
// (docs/datasets-course-library.md, D7): profile a CSV when a version is
// uploaded, carry the instructor's prose onto the next version, and check an
// edited dictionary against the file's header.
//
// Pure functions of the file's text. The library service calls them; nothing
// on the grading path does.

import Foundation

public enum DatasetDictionary {

    /// What one upload tells the library about a file.
    public struct Profile: Sendable, Equatable {
        /// One entry per header column, in header order, with an inferred type
        /// and no prose.
        public let columns: [DatasetColumn]
        /// Data rows, not counting the header.
        public let rowCount: Int
    }

    /// The prose carried from one version onto the next, and the columns whose
    /// prose had nowhere to go.
    public struct CarriedDictionary: Sendable, Equatable {
        public let columns: [DatasetColumn]
        /// Columns of the previous version that the new header does not have,
        /// in the previous version's order. Their prose is dropped.
        public let droppedColumns: [String]
    }

    /// How many data rows type inference reads. A column's type is a hint, and
    /// a bounded read keeps a large upload from costing a full parse twice.
    public static let inferenceRowLimit = 1000

    /// Cells that mean "no value" in common health-data exports. They do not
    /// count against a column's type.
    static let missingTokens: Set<String> = ["", "na", "n/a", "nan", "null", "none", "."]

    /// Profiles `csv`, or returns why it cannot be a library version.
    ///
    /// A library version must be a CSV with a header: the materializer slices
    /// rows, and the dictionary names columns. Each refusal names what is
    /// wrong, because the instructor cannot see the parse.
    public static func profile(csv: String) -> Result<Profile, ProfileError> {
        let (lines, _) = DatasetMaterializer.normalizedLines(of: csv)
        guard let headerLine = lines.first, !headerLine.allSatisfy(\.isWhitespace) else {
            return .failure(.noHeader)
        }
        let header = DatasetMaterializer.splitCSVLine(headerLine)
        if let blank = header.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return .failure(.blankColumnName(position: blank + 1))
        }
        var seen: Set<String> = []
        for name in header where !seen.insert(name).inserted {
            return .failure(.duplicateColumn(name))
        }

        let dataLines = lines.dropFirst()
        var observed = Array(repeating: [String](), count: header.count)
        for line in dataLines.prefix(inferenceRowLimit) {
            let fields = DatasetMaterializer.splitCSVLine(line)
            for (index, value) in fields.enumerated() where index < header.count {
                observed[index].append(value)
            }
        }
        let columns = header.enumerated().map { index, name in
            DatasetColumn(name: name, valueType: inferType(of: observed[index]))
        }
        return .success(Profile(columns: columns, rowCount: dataLines.count))
    }

    /// Why a file cannot be profiled.
    public enum ProfileError: Error, Sendable, Equatable, CustomStringConvertible {
        case noHeader
        case blankColumnName(position: Int)
        case duplicateColumn(String)

        public var description: String {
            switch self {
            case .noHeader:
                return "The file has no header row. A library dataset is a CSV whose first line names its columns."
            case .blankColumnName(let position):
                return "Column \(position) of the header has no name. Every column needs a name."
            case .duplicateColumn(let name):
                return "The header names '\(name)' more than once. Each column name must be unique."
            }
        }
    }

    /// The type every observed value fits, checked from the narrowest to the
    /// widest. A column with no values reads as text.
    static func inferType(of values: [String]) -> DatasetColumn.ValueType {
        let present = values.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !missingTokens.contains($0.lowercased()) }
        guard !present.isEmpty else { return .text }
        if present.allSatisfy({ Int($0) != nil }) { return .integer }
        if present.allSatisfy(isNumber) { return .number }
        if present.allSatisfy({ booleanTokens.contains($0.lowercased()) }) { return .boolean }
        if present.allSatisfy({ $0.wholeMatch(of: isoDate) != nil }) { return .date }
        return .text
    }

    private static let booleanTokens: Set<String> = ["true", "false", "yes", "no", "t", "f", "y", "n"]

    /// A finite decimal number. `Double("nan")` and `Double("inf")` parse, but
    /// a column of them is not a column of measurements.
    private static func isNumber(_ value: String) -> Bool {
        guard let number = Double(value) else { return false }
        return number.isFinite
    }

    /// An ISO 8601 date, with an optional time and offset. A computed property
    /// because `Regex` is not `Sendable`.
    private static var isoDate: Regex<Substring> {
        /\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?/
    }

    /// The previous version's prose, laid onto a new version's inferred
    /// columns by name. The new version's header order and inferred types win;
    /// a column the new header lacks loses its prose and is named in
    /// `droppedColumns`.
    public static func carried(from previous: [DatasetColumn], onto inferred: [DatasetColumn]) -> CarriedDictionary {
        let prose = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = inferred.map { column in
            DatasetColumn(
                name: column.name, valueType: column.valueType,
                description: prose[column.name]?.description, unit: prose[column.name]?.unit)
        }
        let kept = Set(inferred.map(\.name))
        return CarriedDictionary(columns: columns, droppedColumns: previous.map(\.name).filter { !kept.contains($0) })
    }

    /// Why an edited dictionary cannot be saved against a version whose header
    /// is `header`, or nil. An entry must name a column the file has, and must
    /// name it once.
    public static func editIssue(_ entries: [DatasetColumn], header: [String]) -> String? {
        let known = Set(header)
        var seen: Set<String> = []
        for entry in entries {
            guard known.contains(entry.name) else {
                return "The file has no column named '\(entry.name)'."
            }
            guard seen.insert(entry.name).inserted else {
                return "The dictionary describes '\(entry.name)' more than once."
            }
        }
        return nil
    }
}
