// APIServer/Utilities/FreshShortID.swift
//
// The one spelling of a fresh short identifier (#2173). Setups, submissions
// and results are keyed by a prefix, an underscore and eight lowercase hex
// characters; every site used to write the literal itself.

import Foundation

/// A fresh identifier of the form `<prefix>_<8 lowercase hex characters>`.
func freshShortID(prefix: String) -> String {
    "\(prefix)_\(UUID().uuidString.lowercased().prefix(8))"
}
