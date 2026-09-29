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

    /// The month (1–12) in which the term starts.
    public var startMonth: Int {
        switch self {
        case .winter: 1
        case .spring: 5
        case .fall: 9
        }
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
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.season.startMonth < rhs.season.startMonth
    }
}
