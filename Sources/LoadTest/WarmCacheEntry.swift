// LoadTest/WarmCacheEntry.swift
//
// What a warm browser remembers about one kernel boot file.

import Foundation

/// How a warm browser asks for one boot file, learned from one fetch made
/// before the run: not at all when the file is immutable, else with the
/// validators the server sent.
struct WarmCacheEntry: Sendable, Equatable {
    let immutable: Bool
    let etag: String?
    let lastModified: String?

    init(cacheControl: String?, etag: String?, lastModified: String?) {
        let directives = (cacheControl ?? "").lowercased().split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        self.immutable = directives.contains("immutable")
        self.etag = etag
        self.lastModified = lastModified
    }
}
