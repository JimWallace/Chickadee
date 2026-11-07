// APIServer/Services/ZipScriptTextCache.swift
//
// Caches the text of test scripts read from a test setup zip. Each read is an
// `unzip -p` subprocess (`readScriptFromZip`), and the pages that show a suite
// read every script on every request: the student notebook guide on each
// guide-cache miss (every student when a lab section opens the notebook), the
// staff suite outline on each workbench load and save, and the suite editor
// and `get_suite` on each read. A script's text depends only on the zip, not
// on who asks, so one read serves them all until the zip changes.
//
// Scripts are still read one entry at a time through `extractZipEntry`, never
// by extracting the archive to disk: `unzip -d` would restore a symlink entry
// as a symlink, and reading it would follow the link to a host file. Through
// `unzip -p` a symlink entry gives its link text, as it always has.
//
// THE KEY IS STRONGER THAN ZipEntryListCache'S. A cached text is valid for one
// state of the zip: its modification date, its size and a SHA-256 of its
// central directory (every entry's name, sizes and CRC-32) through to the end
// of the file. Every mutation path rewrites the zip (`replaceSetupZip`), but a
// modification date alone is not proof of a new state: Linux stamps files from
// a clock that ticks every few milliseconds, some file systems keep whole
// seconds, and an edit that changes one character keeps the size. The central
// directory changes whenever any entry's content does, and it is a few
// kilobytes at the end of the file, so reading it costs far less than one
// subprocess. A zip whose directory cannot be found (ZIP64, or a damaged end
// record) is not cached: every request reads it as before.

import Core
import Foundation
import Vapor

actor ZipScriptTextCache {
    /// One state of a zip: what a cached text is valid for.
    private struct ZipState: Equatable, Sendable {
        let modified: Date
        let size: UInt64
        let directoryDigest: String
    }

    private struct CachedTexts {
        let state: ZipState
        var texts: [String: String]
        /// Names known to have no text in this state: no such entry, or an
        /// entry that is not UTF-8. Kept so a missing script does not spawn
        /// `unzip` on every request.
        var withoutText: Set<String>
        var byteCount: Int
    }

    /// The texts one fill read for a state, and the names it proved have none.
    private struct Fill: Sendable {
        let texts: [String: String]
        let withoutText: Set<String>
    }

    /// Safety valves, not tuning knobs. Past either, the whole cache is
    /// dropped and refills on demand, as `ZipEntryListCache` does.
    private static let maxZips = 512
    private static let maxTotalBytes = 32 * 1024 * 1024

    /// How many times a request waits for another request's fill before it
    /// reads for itself, uncached.
    private static let maxWaits = 3

    private var cache: [String: CachedTexts] = [:]
    private var totalBytes = 0
    /// One fill per zip at a time: the requests of a lab section opening one
    /// notebook together share it rather than each spawning the same reads.
    private var inFlight: [String: Task<Fill, Never>] = [:]

    /// The UTF-8 text of each of `filenames` in the zip at `zipPath`: exactly
    /// what `readScriptFromZip` returns for each name, with a name absent where
    /// it returns nil.
    func texts(zipPath: String, filenames: [String]) async -> [String: String] {
        let wanted = Set(filenames)
        guard !wanted.isEmpty else { return [:] }

        for _ in 0..<Self.maxWaits {
            // The state is read BEFORE the entries. A zip replaced during the
            // read then files the new texts under the old state, which no
            // later request matches; the reverse order could file old texts
            // under the new state.
            guard let state = await Self.state(ofZipAt: zipPath) else { break }
            if let pending = inFlight[zipPath] {
                _ = await pending.value
                continue
            }
            let cached = cache[zipPath].flatMap { $0.state == state ? $0 : nil }
            let missing = wanted.filter { name in
                cached?.texts[name] == nil && cached?.withoutText.contains(name) != true
            }
            if let cached, missing.isEmpty {
                return cached.texts.filter { wanted.contains($0.key) }
            }

            let fill = Task { await self.fill(zipPath: zipPath, names: missing, state: state) }
            inFlight[zipPath] = fill
            let filled = await fill.value
            var result = (cached?.texts ?? [:]).filter { wanted.contains($0.key) }
            result.merge(filled.texts) { _, new in new }
            return result
        }
        return await readScriptsFromZip(zipPath: zipPath, filenames: wanted)
    }

    /// Reads `names` and files what it learns under `state`. Runs as the zip's
    /// in-flight task, which ends only after the texts are filed, so a request
    /// that waited on it finds them.
    private func fill(zipPath: String, names: Set<String>, state: ZipState) async -> Fill {
        let extracted = await extractZipEntries(zipPath: zipPath, entryNames: names)
        var texts: [String: String] = [:]
        var withoutText: Set<String> = []
        for (name, data) in extracted {
            if let text = String(data: data, encoding: .utf8) {
                texts[name] = text
            } else {
                withoutText.insert(name)
            }
        }
        // A name that did not extract has no text only when the zip lists
        // entries and that name is not one of them. Anything else (an
        // unreadable zip lists nothing; a listed entry that failed to extract)
        // may not repeat, so it is not remembered and the next request reads
        // it again, as before.
        let failed = names.subtracting(extracted.keys)
        if !failed.isEmpty {
            let listed = Set(await listZipEntries(zipPath: zipPath))
            if !listed.isEmpty {
                withoutText.formUnion(failed.subtracting(listed))
            }
        }
        let filled = Fill(texts: texts, withoutText: withoutText)
        store(filled, zipPath: zipPath, state: state)
        inFlight[zipPath] = nil
        return filled
    }

    private func store(_ filled: Fill, zipPath: String, state: ZipState) {
        var entry = CachedTexts(state: state, texts: [:], withoutText: [], byteCount: 0)
        if let existing = cache.removeValue(forKey: zipPath) {
            totalBytes -= existing.byteCount
            if existing.state == state { entry = existing }
        }
        for (name, text) in filled.texts {
            entry.byteCount += text.utf8.count - (entry.texts[name]?.utf8.count ?? 0)
            entry.texts[name] = text
        }
        entry.withoutText.formUnion(filled.withoutText)
        // A suite whose scripts alone pass the byte valve is read each time,
        // as before, rather than emptying the cache on every request.
        guard entry.byteCount <= Self.maxTotalBytes else { return }
        if cache.count >= Self.maxZips || totalBytes + entry.byteCount > Self.maxTotalBytes {
            cache.removeAll()
            totalBytes = 0
        }
        cache[zipPath] = entry
        totalBytes += entry.byteCount
    }

    // MARK: - Zip state

    private static func state(ofZipAt zipPath: String) async -> ZipState? {
        try? await runBlocking { readState(ofZipAt: zipPath) }
    }

    /// The zip's modification date, its size, and a SHA-256 of everything from
    /// the start of its central directory to the end of the file. Nil when the
    /// file cannot be read or its end record cannot be found.
    private static func readState(ofZipAt zipPath: String) -> ZipState? {
        guard let handle = FileHandle(forReadingAtPath: zipPath) else { return nil }
        defer { try? handle.close() }
        guard
            let size = try? handle.seekToEnd(),
            let digest = centralDirectoryDigest(handle: handle, fileSize: size),
            let attributes = try? FileManager.default.attributesOfItem(atPath: zipPath),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return ZipState(modified: modified, size: size, directoryDigest: digest)
    }

    /// The end-of-central-directory record is 22 bytes plus a comment of at
    /// most 65,535 bytes, so it lies within this many bytes of the end.
    private static let endRecordLength = 22
    private static let maxEndRecordSearch = 22 + 0xFFFF
    /// Larger than any setup's directory (about 100 bytes per entry); a zip
    /// claiming more is not fingerprinted.
    private static let maxDirectoryBytes: UInt64 = 16 * 1024 * 1024

    private static func centralDirectoryDigest(handle: FileHandle, fileSize: UInt64) -> String? {
        guard fileSize >= UInt64(endRecordLength) else { return nil }
        let tailLength = min(fileSize, UInt64(maxEndRecordSearch))
        let tailStart = fileSize - tailLength
        guard (try? handle.seek(toOffset: tailStart)) != nil,
            let tailData = try? handle.read(upToCount: Int(tailLength)),
            tailData.count == Int(tailLength)
        else { return nil }
        let tail = [UInt8](tailData)

        // The end record is the last signature whose comment length runs
        // exactly to the end of the file.
        var position = tail.count - endRecordLength
        var recordStart: Int?
        while position >= 0 {
            if tail[position] == 0x50, tail[position + 1] == 0x4B, tail[position + 2] == 0x05,
                tail[position + 3] == 0x06,
                position + endRecordLength + Int(littleEndian16(tail, at: position + 20)) == tail.count
            {
                recordStart = position
                break
            }
            position -= 1
        }
        guard let recordStart else { return nil }

        let directorySize = UInt64(littleEndian32(tail, at: recordStart + 12))
        let directoryOffset = UInt64(littleEndian32(tail, at: recordStart + 16))
        // ZIP64 stores 0xFFFFFFFF here and the real values elsewhere.
        guard directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { return nil }
        let recordOffset = tailStart + UInt64(recordStart)
        guard directoryOffset + directorySize <= recordOffset,
            recordOffset - directoryOffset <= maxDirectoryBytes
        else { return nil }

        if directoryOffset >= tailStart {
            return sha256HexDigest(Data(tail[Int(directoryOffset - tailStart)...]))
        }
        guard (try? handle.seek(toOffset: directoryOffset)) != nil,
            let rest = try? handle.readToEnd(),
            UInt64(rest.count) == fileSize - directoryOffset
        else { return nil }
        return sha256HexDigest(rest)
    }

    private static func littleEndian16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func littleEndian32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }
}

struct ZipScriptTextCacheKey: StorageKey {
    typealias Value = ZipScriptTextCache
}

extension Application {
    var zipScriptTextCache: ZipScriptTextCache {
        lazyStored(ZipScriptTextCacheKey.self) {
            ZipScriptTextCache()
        }
    }
}
