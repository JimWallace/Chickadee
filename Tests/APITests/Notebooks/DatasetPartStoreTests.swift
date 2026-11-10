import Core
import Foundation
import Testing

@testable import APIServer

/// `DatasetPartStore` (docs/dataset-shared-delivery.md) writes each part of a
/// partition once per fingerprint, publishes the directory whole, and sweeps
/// fingerprints that are no longer current once they are a day old.
@Suite final class DatasetPartStoreTests {
    private let root: String
    private let partsRoot: String
    private let source: String
    private let pool = "id,ward\n1,A\n2,B\n3,C\n4,D\n5,E\n"

    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dataset-parts-\(UUID().uuidString)")
            .path
        partsRoot = DatasetPartStore.root(testSetupsDirectory: root)
        try FileManager.default.createDirectory(atPath: root + "/shared", withIntermediateDirectories: true)
        source = root + "/shared/cases.csv"
        try pool.write(toFile: source, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func spec(_ partCount: Int) -> DatasetSpec {
        DatasetSpec(file: "cases.csv", kind: .partition, partCount: partCount)
    }

    private func ensure(_ spec: DatasetSpec, keeping: Set<String> = [], now: Date = Date()) throws -> String {
        let fingerprint = try #require(DatasetPartStore.fingerprint(spec: spec, sourcePath: source))
        return try DatasetPartStore.ensureParts(
            spec: spec, sourcePath: source, root: partsRoot, setupID: "setup", fingerprint: fingerprint,
            keeping: keeping, now: now)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    @Test("Each stored part is what grading materializes for that part")
    func partsMatchTheMaterializer() throws {
        let spec = spec(2)
        let directory = try ensure(spec)

        for part in 0..<2 {
            #expect(
                try read(directory + DatasetPartStore.partFileName(part))
                    == DatasetMaterializer.materialize(source: pool, spec: spec, seedHex: "00", dealNumber: part))
        }
        #expect(try read(directory + DatasetPartStore.headerFileName) == "id,ward\n")
    }

    @Test("A stored fingerprint is not written again")
    func publishedPartsAreNotRewritten() throws {
        let directory = try ensure(spec(2))
        try "TAMPERED".write(toFile: directory + DatasetPartStore.partFileName(0), atomically: true, encoding: .utf8)

        #expect(try ensure(spec(2)) == directory)
        #expect(try read(directory + DatasetPartStore.partFileName(0)) == "TAMPERED")
    }

    @Test("A new part count is a new directory, and no staging directory is left")
    func newSpecIsNewDirectory() throws {
        let two = try ensure(spec(2))
        let three = try ensure(spec(3))

        #expect(two != three)
        #expect(FileManager.default.fileExists(atPath: three + DatasetPartStore.partFileName(2)))
        let entries = try FileManager.default.contentsOfDirectory(atPath: partsRoot + "setup")
        #expect(!entries.contains { $0.hasPrefix(".tmp-") })
    }

    @Test("Retention starts when a sweep first finds a fingerprint superseded, not when it was made")
    func retentionStartsAtSupersession() throws {
        let fm = FileManager.default
        let old = try ensure(spec(2))
        // Published long ago: age from creation alone would remove it at once.
        let longAgo = Date().addingTimeInterval(-10 * DatasetPartStore.staleRetention)
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: old)

        let current = try ensure(spec(3))

        #expect(fm.fileExists(atPath: old + DatasetPartStore.partFileName(0)), "kept, and marked superseded")
        #expect(fm.fileExists(atPath: old + DatasetPartStore.supersededMarkerName))
        #expect(!fm.fileExists(atPath: current + DatasetPartStore.supersededMarkerName))
    }

    @Test("A superseded fingerprint goes once its mark is past retention; a current one stays")
    func sweepRemovesFingerprintsMarkedPastRetention() throws {
        let fm = FileManager.default
        let old = try ensure(spec(2))
        let kept = try ensure(spec(4))
        let current = try ensure(spec(3))
        let fingerprint = { (count: Int) in
            try #require(DatasetPartStore.fingerprint(spec: self.spec(count), sourcePath: self.source))
        }
        let setupDir = partsRoot + "setup/"
        let keeping: Set<String> = [try fingerprint(3), try fingerprint(4)]

        DatasetPartStore.sweep(setupDirectory: setupDir, keeping: keeping, now: Date())
        let later = Date().addingTimeInterval(DatasetPartStore.staleRetention + 60)
        DatasetPartStore.sweep(setupDirectory: setupDir, keeping: keeping, now: later)

        #expect(!fm.fileExists(atPath: old))
        #expect(fm.fileExists(atPath: kept))
        #expect(fm.fileExists(atPath: current))
    }

    @Test("A fingerprint that is current again loses its mark")
    func currentAgainClearsTheMark() throws {
        let fm = FileManager.default
        let two = try ensure(spec(2))
        _ = try ensure(spec(3))
        #expect(fm.fileExists(atPath: two + DatasetPartStore.supersededMarkerName))

        let twoFingerprint = try #require(DatasetPartStore.fingerprint(spec: spec(2), sourcePath: source))
        DatasetPartStore.sweep(setupDirectory: partsRoot + "setup/", keeping: [twoFingerprint], now: Date())

        #expect(!fm.fileExists(atPath: two + DatasetPartStore.supersededMarkerName))
    }

    @Test("A missing source has no fingerprint")
    func missingSourceHasNoFingerprint() {
        #expect(DatasetPartStore.fingerprint(spec: spec(2), sourcePath: root + "/shared/absent.csv") == nil)
    }
}
