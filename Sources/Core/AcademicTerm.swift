// Core/AcademicTerm.swift
//
// The year and term of one course offering (docs/course-terms.md).  The three
// seasons follow the University of Waterloo calendar: Winter (January–April),
// Spring (May–August) and Fall (September–December).
//
// Both halves mirror nullable columns on `courses` (`term_year`,
// `term_season`).  A course created before terms existed has neither, and
// reads as "no term recorded" — never as a term guessed from its creation
// date.

import Foundation

/// One of the three Waterloo terms.  Declared in calendar order, so
/// `allCases` is also the order of the terms within one year.
public enum TermSeason: String, Codable, Sendable, CaseIterable {
    case winter
    case spring
    case fall

    /// The name shown in the UI: "Winter", "Spring" or "Fall".
    public var displayName: String {
        switch self {
        case .winter: "Winter"
        case .spring: "Spring"
        case .fall: "Fall"
        }
    }

    /// The letter used in short term labels: "W", "S" or "F".
    public var initial: String {
        switch self {
        case .winter: "W"
        case .spring: "S"
        case .fall: "F"
        }
    }

    /// The month (1–12) in which the term starts.
    public var startMonth: Int {
        switch self {
        case .winter: 1
        case .spring: 5
        case .fall: 9
        }
    }

    /// The term a month (1–12) falls in: January to April is Winter, May to
    /// August is Spring, and September to December is Fall.
    public static func containing(month: Int) -> TermSeason {
        switch month {
        case ..<5: .winter
        case ..<9: .spring
        default: .fall
        }
    }

    /// The term that `date` falls in, on the Waterloo calendar.
    public static func current(at date: Date = Date()) -> TermSeason {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return containing(month: calendar.component(.month, from: date))
    }
}

/// A year plus a season, e.g. Fall 2026.  Ordered chronologically.
public struct AcademicTerm: Codable, Sendable, Hashable, Comparable {
    /// The years a term may carry: any four-digit year.
    public static let yearRange = 1000...9999

    public let year: Int
    public let season: TermSeason

    /// Returns nil when `year` is not a four-digit year.
    public init?(year: Int, season: TermSeason) {
        guard Self.yearRange.contains(year) else { return nil }
        self.year = year
        self.season = season
    }

    /// Resolves the two stored course columns.  Returns nil unless both are
    /// present and valid: half a term is not a term.
    public static func resolve(year: Int?, season rawSeason: String?) -> AcademicTerm? {
        guard let year, let rawSeason, let season = TermSeason(rawValue: rawSeason) else {
            return nil
        }
        return AcademicTerm(year: year, season: season)
    }

    /// "Fall 2026".
    public var displayName: String { "\(season.displayName) \(year)" }

    /// "F26": the season initial and the last two digits of the year. The
    /// compact form for tight places such as the course tab strip.
    public var shortLabel: String {
        let twoDigits = year % 100
        return season.initial + (twoDigits < 10 ? "0\(twoDigits)" : "\(twoDigits)")
    }

    /// Parses a `shortLabel` ("F26", case-insensitive) back into a term. A
    /// short label carries only two digits, so it names a year from 2000 to
    /// 2099; that is the range Chickadee writes into course URLs.
    public init?(shortLabel label: String) {
        guard label.count == 3, let initial = label.first,
            let season = TermSeason.allCases.first(where: { $0.initial == initial.uppercased() }),
            label.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
            let twoDigits = Int(label.dropFirst())
        else { return nil }
        self.init(year: 2000 + twoDigits, season: season)
    }

    /// A number that increases by one per term, in calendar order. Use it
    /// as a sort value where a `Comparable` value cannot go (a table cell).
    public var ordinal: Int {
        year * TermSeason.allCases.count + (TermSeason.allCases.firstIndex(of: season) ?? 0)
    }

    /// The term that follows this one: Winter → Spring → Fall → next Winter.
    /// Nil only past the last four-digit year.
    public var next: AcademicTerm? {
        switch season {
        case .winter: AcademicTerm(year: year, season: .spring)
        case .spring: AcademicTerm(year: year, season: .fall)
        case .fall: AcademicTerm(year: year + 1, season: .winter)
        }
    }

    /// The term that contains `date`, using the start months of the three
    /// seasons.  A suggestion for a form default, never a stored value.
    public static func containing(
        _ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> AcademicTerm? {
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        let season = TermSeason.allCases.last { $0.startMonth <= month } ?? .winter
        return AcademicTerm(year: year, season: season)
    }

    private enum CodingKeys: String, CodingKey { case year, season }

    /// Decoding applies the same four-digit rule as `init?(year:season:)`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let season = try container.decode(TermSeason.self, forKey: .season)
        guard let term = AcademicTerm(year: year, season: season) else {
            throw DecodingError.dataCorruptedError(
                forKey: .year, in: container, debugDescription: "\(year) is not a four-digit year")
        }
        self = term
    }

    public static func < (lhs: AcademicTerm, rhs: AcademicTerm) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}
