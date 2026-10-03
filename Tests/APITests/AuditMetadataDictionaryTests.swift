// Tests/APITests/AuditMetadataDictionaryTests.swift
//
// The one reader and writer of `audit_log.metadata` (#1931).

import Testing

@testable import APIServer

@Suite struct AuditMetadataDictionaryTests {

    private func entry(metadata: String?) -> APIAuditLogEntry {
        APIAuditLogEntry(action: AuditAction.logout.rawValue, metadata: metadata)
    }

    @Test func theColumnReadsAsADictionary() {
        let row = entry(metadata: #"{"course_id":"c1","outcome":"success"}"#)
        #expect(row.metadataDictionary == ["course_id": "c1", "outcome": "success"])
    }

    @Test(arguments: [nil, "", "not-json", "[]", #"{"count":3}"#])
    func aColumnThatIsNotAnObjectOfStringsReadsAsEmpty(metadata: String?) {
        #expect(entry(metadata: metadata).metadataDictionary.isEmpty)
    }

    /// Tests elsewhere match substrings such as `"outcome":"success"`, so the
    /// stored form stays compact JSON with sorted keys.
    @Test func settingStoresCompactJSONWithSortedKeys() {
        let row = entry(metadata: nil)
        row.metadataDictionary = ["outcome": "success", "client": "abc"]
        #expect(row.metadata == #"{"client":"abc","outcome":"success"}"#)
    }

    @Test func settingAnEmptyDictionaryStoresNil() {
        let row = entry(metadata: #"{"a":"b"}"#)
        row.metadataDictionary = [:]
        #expect(row.metadata == nil)
    }

    @Test func mergingKeepsOldKeysAndReplacesChangedOnes() {
        let row = entry(metadata: #"{"a":"1","b":"2"}"#)
        row.metadataDictionary.merge(["b": "3", "c": "4"]) { _, new in new }
        #expect(row.metadataDictionary == ["a": "1", "b": "3", "c": "4"])
    }

    @Test func aValueWithSlashesAndUnicodeRoundTrips() {
        let row = entry(metadata: nil)
        row.metadataDictionary = ["path": "/admin/courses", "name": "Zoë"]
        #expect(row.metadataDictionary == ["path": "/admin/courses", "name": "Zoë"])
    }
}
