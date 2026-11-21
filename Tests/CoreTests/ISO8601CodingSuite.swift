// Tests/CoreTests/ISO8601CodingSuite.swift
//
// The JSON coders that the Codable suites share. They were one suite,
// `CoreCodableTests`, until it was split by subject; each piece still encodes
// and decodes dates as ISO 8601, as the wire does.

import Foundation

/// A suite whose tests round-trip values through JSON with ISO 8601 dates.
protocol ISO8601CodingSuite {}

extension ISO8601CodingSuite {
    var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
