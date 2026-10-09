// Core/ISO8601.swift
//
// The one spelling of an ISO 8601 date-time (#2492): internet date-time, in
// UTC, with no fractional seconds — the default `ISO8601DateFormatter`. The
// code used to construct that formatter inline in some fifty places.

import Foundation

/// Formats `date` as an ISO 8601 date-time, such as "2026-10-08T21:30:00Z".
public func iso8601String(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// Parses an ISO 8601 date-time in the form `iso8601String` writes, or returns
/// nil.
public func iso8601Date(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}
