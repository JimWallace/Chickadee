// Core/BugHuntSpec.swift
//
// The `bugHunt` block of a bug-hunt activity (docs/bug-hunt-code-map.md): which
// suite entries count as the class's items, and, optionally, the code the
// projector shows with each item's lines lit once the class covers it. The
// kind is `bugHunt`; the block is meaningless on any other kind and is refused
// there at save.
//
// The items are suite entries named by script filename, the name an author
// passes to `author_script`. Coverage is recorded under the runner's outcome
// name (`runnerOutcomeTestName`), so a reader translates through the suite.

import Foundation

/// One region of the code map: the lines a suite entry stands for.
public struct BugHuntRegion: Codable, Equatable, Sendable {
    /// The suite entry's script filename, for example `publictest_bug_01.py`.
    public let item: String
    /// A line or an inclusive range, 1-based: "7" or "12-18".
    public let lines: String

    public init(item: String, lines: String) {
        self.item = item
        self.lines = lines
    }

    /// The range `lines` names, or nil when it is not "N" or "N-M" with
    /// 1 <= N <= M.
    public var lineRange: ClosedRange<Int>? {
        let parts = lines.split(separator: "-", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), let start = Int(parts[0]) else { return nil }
        let end = parts.count == 2 ? Int(parts[1]) : start
        guard let end, start >= 1, end >= start else { return nil }
        return start...end
    }
}

/// How one line of the code map shows on the projector.
public enum BugHuntLineState: String, Codable, CaseIterable, Sendable {
    /// No region covers the line.
    case plain
    /// Every region on the line is still uncovered.
    case dark
    /// Some of the regions on the line are covered.
    case partial
    /// Every region on the line is covered.
    case lit
}

/// The first rule a `bugHunt` block breaks.
public enum BugHuntSpecProblem: Equatable, Sendable {
    case noItems
    case duplicateItem(String)
    case codeTooLarge
    case regionsWithoutCode
    case codeWithoutRegions
    case unreadableLines(String)
    case linesOutsideCode(String)
    case regionItemNotListed(String)

    public var message: String {
        switch self {
        case .noItems:
            return "A bug hunt needs at least one item: the suite entries the class covers together."
        case .duplicateItem(let item):
            return "The item \"\(item)\" is listed twice."
        case .codeTooLarge:
            return
                "The code map shows at most \(BugHuntSpec.maxCodeLines) lines and "
                + "\(BugHuntSpec.maxCodeBytes / 1024) KB of code."
        case .regionsWithoutCode:
            return "Regions need the code they point into. Add the code, or remove the regions."
        case .codeWithoutRegions:
            return "The code map needs at least one region that ties an item to its lines."
        case .unreadableLines(let lines):
            return "\"\(lines)\" is not a line or a range of lines. Write \"7\" or \"12-18\"."
        case .linesOutsideCode(let lines):
            return "The lines \"\(lines)\" fall outside the code."
        case .regionItemNotListed(let item):
            return "The region for \"\(item)\" names an item that is not in the item list."
        }
    }
}

/// The `bugHunt` block of a `bugHunt` activity.
public struct BugHuntSpec: Codable, Equatable, Sendable {
    public static let maxCodeLines = 400
    public static let maxCodeBytes = 32 * 1024

    /// The suite entries the class covers together, by script filename. The
    /// projector's percentage is the share of these the class has covered.
    public let items: [String]
    /// The code the projector shows. Nil shows the percentage alone, so the
    /// class has to coordinate in the room.
    public let code: String?
    /// The lines each item stands for. Empty when there is no code.
    public let regions: [BugHuntRegion]

    public init(items: [String], code: String? = nil, regions: [BugHuntRegion] = []) {
        self.items = items
        self.code = code?.isEmpty == true ? nil : code
        self.regions = regions
    }

    private enum CodingKeys: String, CodingKey { case items, code, regions }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            items: try c.decodeIfPresent([String].self, forKey: .items) ?? [],
            code: try c.decodeIfPresent(String.self, forKey: .code),
            regions: try c.decodeIfPresent([BugHuntRegion].self, forKey: .regions) ?? [])
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(code, forKey: .code)
        if !regions.isEmpty { try c.encode(regions, forKey: .regions) }
    }

    /// The code split into lines, or empty with no code.
    public var codeLines: [String] {
        guard let code else { return [] }
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// True when the projector shows the code, not the percentage alone.
    public var showsCode: Bool { code != nil }

    /// The first rule this block breaks, or nil when it can be saved. Whether
    /// each item names a suite entry is the caller's check: the suite is not
    /// in this block.
    public var problem: BugHuntSpecProblem? {
        guard !items.isEmpty else { return .noItems }
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item).inserted else { return .duplicateItem(item) }
        }
        guard let code else {
            return regions.isEmpty ? nil : .regionsWithoutCode
        }
        let lineCount = codeLines.count
        guard code.utf8.count <= Self.maxCodeBytes, lineCount <= Self.maxCodeLines else { return .codeTooLarge }
        guard !regions.isEmpty else { return .codeWithoutRegions }
        for region in regions {
            guard let range = region.lineRange else { return .unreadableLines(region.lines) }
            guard range.upperBound <= lineCount else { return .linesOutsideCode(region.lines) }
            guard seen.contains(region.item) else { return .regionItemNotListed(region.item) }
        }
        return nil
    }

    /// Each line's state, given the items the class has covered (by script
    /// filename). Empty with no code.
    public func lineStates(covered: Set<String>) -> [BugHuntLineState] {
        let lines = codeLines
        var total = Array(repeating: 0, count: lines.count)
        var lit = Array(repeating: 0, count: lines.count)
        for region in regions {
            guard let range = region.lineRange else { continue }
            for line in range where line <= lines.count {
                total[line - 1] += 1
                if covered.contains(region.item) { lit[line - 1] += 1 }
            }
        }
        return zip(total, lit).map { total, lit in
            if total == 0 { return .plain }
            if lit == 0 { return .dark }
            return lit == total ? .lit : .partial
        }
    }
}
