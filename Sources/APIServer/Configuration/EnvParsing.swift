// APIServer/Configuration/EnvParsing.swift
//
// Shared helpers for reading typed values out of Vapor's `Environment`.
// All env-var parsing in the AppConfig tree goes through these so the
// semantics stay identical across substructs.

import Foundation
import Vapor

/// Trimmed, non-empty env value. Returns nil for unset, blank, or whitespace-only.
func trimmedEnv(_ key: String) -> String? {
    let raw = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw, !raw.isEmpty else { return nil }
    return raw
}

/// Parses common boolean spellings: 1/true/yes/on → true, 0/false/no/off → false,
/// anything else (or unset) → nil so callers can apply their own default.
func environmentBool(_ key: String) -> Bool? {
    guard let raw = trimmedEnv(key)?.lowercased() else { return nil }
    switch raw {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
}

/// Integer env var, nil if unset or non-numeric.
func environmentInt(_ key: String) -> Int? {
    guard let raw = trimmedEnv(key), let value = Int(raw) else { return nil }
    return value
}

/// Double env var, nil if unset or non-numeric.
func environmentDouble(_ key: String) -> Double? {
    guard let raw = trimmedEnv(key), let value = Double(raw) else { return nil }
    return value
}

/// Splits a comma/semicolon/newline-separated identifier list and lowercases each entry.
/// Used by SSO allowlists.
func parseSSOIdentityAllowlist(_ raw: String?) -> Set<String> {
    guard let raw else { return [] }
    let values =
        raw
        .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline })
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    return Set(values)
}
