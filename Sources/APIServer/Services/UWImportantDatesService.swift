// APIServer/Services/UWImportantDatesService.swift
//
// Fetches and caches the University of Waterloo important dates iCalendar feed.
// Results are cached for 24 hours to avoid hammering the UW server on every
// instructor due-date change.

import Vapor
import Foundation

// MARK: - Model

struct UWImportantDate: Codable, Sendable {
    /// ISO-8601 date string, e.g. "2026-03-21"
    let startDate: String
    /// ISO-8601 date string (exclusive end per iCalendar convention), e.g. "2026-03-22"
    let endDate: String
    let title: String
}

// MARK: - Actor

actor UWImportantDatesCache {
    private let feedURL = "https://uwaterloo.ca/important-dates/important-dates/important_dates_ical.ics"
    private let cacheDuration: TimeInterval = 60 * 60 * 24 // 24 hours

    private var cached: [UWImportantDate] = []
    private var cachedAt: Date?

    func fetchDates(client: Client, logger: Logger) async -> [UWImportantDate] {
        if let cachedAt, Date().timeIntervalSince(cachedAt) < cacheDuration {
            return cached
        }
        do {
            let response = try await client.get(URI(string: feedURL))
            guard response.status == .ok else {
                logger.warning("UW important dates fetch returned HTTP \(response.status.code)")
                return cached
            }
            var body = response.body ?? ByteBuffer()
            let text = body.readString(length: body.readableBytes) ?? ""
            let parsed = parseICS(text)
            cached = parsed
            cachedAt = Date()
            return parsed
        } catch {
            logger.warning("UW important dates fetch failed: \(error)")
            return cached
        }
    }

    // MARK: - iCalendar Parser

    /// Extracts VEVENT blocks and returns one UWImportantDate per event.
    /// Handles both DATE-only (DTSTART;VALUE=DATE:YYYYMMDD) and DATE-TIME forms.
    private func parseICS(_ text: String) -> [UWImportantDate] {
        var results: [UWImportantDate] = []

        // Split on VEVENT boundaries
        let blocks = text.components(separatedBy: "BEGIN:VEVENT")
        for block in blocks.dropFirst() {
            guard let startDate = extractDate(key: "DTSTART", from: block),
                  let title = extractSummary(from: block) else {
                continue
            }
            // DTEND is exclusive in iCalendar; default to startDate + 1 day if absent
            let endDate = extractDate(key: "DTEND", from: block) ?? nextDay(startDate)
            results.append(UWImportantDate(startDate: startDate, endDate: endDate, title: title))
        }

        return results
    }

    /// Extracts a line like DTSTART;VALUE=DATE:20260321 or DTSTART:20260321 → "2026-03-21"
    private func extractDate(key: String, from block: String) -> String? {
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Match e.g. "DTSTART;VALUE=DATE:20260321" or "DTSTART:20260321"
            guard trimmed.hasPrefix(key) else { continue }
            let colonIdx = trimmed.firstIndex(of: ":") ?? trimmed.endIndex
            let raw = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Take the date portion (first 8 digits)
            let digits = raw.prefix(8)
            guard digits.count == 8, digits.allSatisfy(\.isNumber) else { continue }
            let y = digits.prefix(4)
            let m = digits.dropFirst(4).prefix(2)
            let d = digits.dropFirst(6).prefix(2)
            return "\(y)-\(m)-\(d)"
        }
        return nil
    }

    /// Extracts SUMMARY, handling folded lines (continuation lines start with a space/tab).
    private func extractSummary(from block: String) -> String? {
        let lines = block.components(separatedBy: "\n")
        var inSummary = false
        var accumulated = ""
        for line in lines {
            let raw = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if raw.hasPrefix("SUMMARY:") || raw.hasPrefix("SUMMARY;") {
                // Drop the property name
                if let colonIdx = raw.firstIndex(of: ":") {
                    accumulated = String(raw[raw.index(after: colonIdx)...])
                }
                inSummary = true
            } else if inSummary {
                if raw.hasPrefix(" ") || raw.hasPrefix("\t") {
                    // Folded continuation line
                    accumulated += raw.dropFirst()
                } else {
                    break
                }
            }
        }
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unescape iCalendar backslash sequences
        let unescaped = trimmed
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\\\", with: "\\")
        return unescaped.isEmpty ? nil : unescaped
    }

    private func nextDay(_ isoDate: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let date = formatter.date(from: isoDate) else { return isoDate }
        let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date) ?? date
        return formatter.string(from: next)
    }
}

// MARK: - Application Storage

private struct UWImportantDatesCacheKey: StorageKey {
    typealias Value = UWImportantDatesCache
}

extension Application {
    var uwImportantDatesCache: UWImportantDatesCache {
        get {
            if let existing = storage[UWImportantDatesCacheKey.self] {
                return existing
            }
            let created = UWImportantDatesCache()
            storage[UWImportantDatesCacheKey.self] = created
            return created
        }
        set { storage[UWImportantDatesCacheKey.self] = newValue }
    }
}
