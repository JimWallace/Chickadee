// Tests/CoreTests/DatasetResolverTests.swift
//
// Pins DatasetResolver (Phase 1 datasets): it reads each declared dataset's
// source pool from a directory and returns the student's deterministic slice,
// delegating slicing to DatasetMaterializer. The no-dataset / no-seed / missing
// -file cases must return nil (the strict no-op that keeps every non-dataset
// assignment unaffected). Also covers Job's new personalizedFiles round-trip.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetResolverTests {

    private let seed = String(repeating: "a1b2", count: 16)

    /// Creates a fresh temp directory and removes it after `body`.
    private func withTempDir(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir.path)
    }

    private func indexedCSV(_ n: Int) -> String {
        "id\n" + (0..<n).map(String.init).joined(separator: "\n") + "\n"
    }

    @Test func resolvesDeterministicSliceForDeclaredDataset() throws {
        try withTempDir { dir in
            let pool = indexedCSV(100)
            try pool.write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 10)])

            let files = try #require(
                DatasetResolver.resolve(manifest: manifest, seedHex: seed, sourceDirectory: dir))
            let slice = try #require(files["cases.csv"])

            // Delegates to DatasetMaterializer — identical bytes.
            #expect(
                slice
                    == DatasetMaterializer.materialize(
                        source: pool, spec: DatasetSpec(file: "cases.csv", sampleSize: 10),
                        seedHex: seed))
            #expect(slice.hasPrefix("id\n"))
            #expect(slice.split(separator: "\n").dropFirst().count == 10)
        }
    }

    @Test func trailingSlashOnDirectoryIsOptional() throws {
        try withTempDir { dir in
            try indexedCSV(50).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 5)])
            let withSlash = DatasetResolver.resolve(
                manifest: manifest, seedHex: seed, sourceDirectory: dir + "/")
            let withoutSlash = DatasetResolver.resolve(
                manifest: manifest, seedHex: seed, sourceDirectory: dir)
            #expect(withSlash?["cases.csv"] == withoutSlash?["cases.csv"])
            #expect(withSlash?["cases.csv"] != nil)
        }
    }

    @Test func noDatasetsReturnsNil() throws {
        try withTempDir { dir in
            #expect(
                DatasetResolver.resolve(manifest: TestProperties(), seedHex: seed, sourceDirectory: dir)
                    == nil)
        }
    }

    @Test func noSeedReturnsNil() throws {
        try withTempDir { dir in
            try indexedCSV(50).write(toFile: dir + "/cases.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 5)])
            #expect(DatasetResolver.resolve(manifest: manifest, seedHex: nil, sourceDirectory: dir) == nil)
            #expect(DatasetResolver.resolve(manifest: manifest, seedHex: "", sourceDirectory: dir) == nil)
        }
    }

    @Test func missingSourceFileIsSkipped() throws {
        try withTempDir { dir in
            // Declared but never written to disk.
            let manifest = TestProperties(datasets: [DatasetSpec(file: "absent.csv", sampleSize: 5)])
            #expect(DatasetResolver.resolve(manifest: manifest, seedHex: seed, sourceDirectory: dir) == nil)
        }
    }

    @Test func pathCarryingSpecIsSkippedNotRead() throws {
        // #1104 — a spec whose file carries path components must never be
        // joined onto the source directory (it could read any server-readable
        // file, e.g. ../../.worker-secret). It is skipped like a missing file.
        try withTempDir { dir in
            let outside = dir + "/outside-secret.txt"
            try "hunter2".write(toFile: outside, atomically: true, encoding: .utf8)
            let inner = dir + "/pool"
            try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
            let manifest = TestProperties(datasets: [
                DatasetSpec(file: "../outside-secret.txt", sampleSize: 5),
                DatasetSpec(file: "/etc/hostname", sampleSize: 5),
                DatasetSpec(file: "..", sampleSize: 5),
            ])
            #expect(
                DatasetResolver.resolve(manifest: manifest, seedHex: seed, sourceDirectory: inner)
                    == nil)
        }
    }

    @Test func resolvesMultipleDatasetsIndependently() throws {
        try withTempDir { dir in
            try indexedCSV(80).write(toFile: dir + "/a.csv", atomically: true, encoding: .utf8)
            try indexedCSV(80).write(toFile: dir + "/b.csv", atomically: true, encoding: .utf8)
            let manifest = TestProperties(datasets: [
                DatasetSpec(file: "a.csv", sampleSize: 5),
                DatasetSpec(file: "b.csv", sampleSize: 7),
            ])
            let files = try #require(
                DatasetResolver.resolve(manifest: manifest, seedHex: seed, sourceDirectory: dir))
            #expect(files["a.csv"]?.split(separator: "\n").dropFirst().count == 5)
            #expect(files["b.csv"]?.split(separator: "\n").dropFirst().count == 7)
        }
    }
}

@Suite struct JobPersonalizedFilesCodableTests {

    @Test func jobWithoutPersonalizedFilesDecodesNil() throws {
        let json = #"""
            {"submissionID":"s1","testSetupID":"t1","attemptNumber":1,
             "submissionURL":"https://example.com/s","testSetupURL":"https://example.com/t",
             "manifest":{"schemaVersion":1}}
            """#
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.personalizedFiles == nil)
    }

    @Test func jobPersonalizedFilesRoundTrip() throws {
        let url = try #require(URL(string: "https://example.com/x"))
        let job = Job(
            submissionID: "s1", testSetupID: "t1", attemptNumber: 1,
            submissionURL: url, testSetupURL: url, manifest: TestProperties(),
            personalizedFiles: ["cases.csv": "id\n1\n2\n"])
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(Job.self, from: data)
        #expect(decoded.personalizedFiles == ["cases.csv": "id\n1\n2\n"])
    }
}
