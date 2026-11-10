// APIServer/Utilities/AlertText.swift
//
// Wording shared by the health-alert summaries. An alert summary names what it
// is about (runners, assignments), states a time in minutes or hours, and says
// where to look. These helpers keep the rules saying it the same way.

import Foundation

/// How many names an alert summary lists before ", and N more". It keeps a
/// long list from outgrowing a webhook's message limit (Pushover: about 1024
/// characters). The full list stays in the alert's `details`.
let alertNamedListLimit = 5

/// "Hawk, Sparrow" or "R1, R2, R3, R4, R5, and 3 more".
func alertNamedList(_ names: [String], limit: Int = alertNamedListLimit) -> String {
    var shown = Array(names.prefix(limit))
    if names.count > limit {
        shown.append("and \(names.count - limit) more")
    }
    return shown.joined(separator: ", ")
}

/// "45m", "3h 20m", "5d 13h": short enough for an alert summary line.
func formatQuietDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds) / 60
    let hours = minutes / 60
    let days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
}
