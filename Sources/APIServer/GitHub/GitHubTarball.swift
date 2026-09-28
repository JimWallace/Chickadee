// APIServer/GitHub/GitHubTarball.swift
//
// Converts a GitHub commit tarball into a submission zip
// (docs/github-submissions.md "Converting the tarball"):
//
// - removes the one top-level directory, `{owner}-{repo}-{sha}/`;
// - keeps regular files only, so symbolic links, hard links and devices are
//   dropped and nothing can point outside the workspace;
// - refuses the commit when its files total more than `maxFileBytes`.
//
// The limit is counted while the archive is read: `gzip` runs with a cap on
// its output, so a compressed bomb stops at the cap instead of filling memory
// or disk. The tar reader is small because it needs only the formats `git
// archive` writes (ustar with pax extended headers).

import Core
import Foundation
import Subprocess

enum GitHubTarball {
    /// The upload body limit (`defaultMaxBodySize`), so a GitHub submission
    /// can be no larger than an upload.
    static let maxFileBytes = 10 * 1024 * 1024
    /// The cap on the decompressed tar: the files plus room for the 512-byte
    /// headers and padding of a repository with many small files.
    static let maxTarBytes = 4 * maxFileBytes

    struct Entry: Equatable, Sendable {
        let path: String
        let data: Data
    }

    /// Converts `gzipped` into a zip at `zipPath`.
    static func writeZip(fromGzippedTar gzipped: Data, to zipPath: String) async throws {
        let entries = try files(inTar: try await gunzip(gzipped))
        guard !entries.isEmpty else { throw GitHubSubmitError.empty }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("chickadee_github_\(UUID().uuidString)")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }
        for entry in entries {
            let url = workDir.appendingPathComponent(entry.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: url)
        }
        try await createZipArchive(sourceDir: workDir, outputPath: zipPath)
    }

    /// Decompresses `gzipped`, refusing output larger than `maxTarBytes`.
    static func gunzip(_ gzipped: Data, limit: Int = maxTarBytes) async throws -> Data {
        let fm = FileManager.default
        let input = fm.temporaryDirectory.appendingPathComponent("chickadee_github_\(UUID().uuidString).tar.gz")
        try gzipped.write(to: input)
        defer { try? fm.removeItem(at: input) }
        do {
            let result = try await Subprocess.run(
                .name("gzip"),
                arguments: ["-dc", input.path],
                output: .data(limit: limit),
                error: .discarded)
            guard case .exited(0) = result.terminationStatus else { throw GitHubSubmitError.unreadable }
            return result.standardOutput
        } catch let error as SubprocessError where error.code == .outputLimitExceeded {
            throw GitHubSubmitError.tooLarge
        }
    }

    /// The regular files in `tar`, with the top-level directory removed.
    static func files(inTar tar: Data, maxFileBytes: Int = maxFileBytes) throws -> [Entry] {
        let bytes = [UInt8](tar)
        var entries: [Entry] = []
        var total = 0
        var offset = 0
        // A pax `x` header or a GNU `L` header names the entry that follows.
        var pendingPath: String?
        while offset + 512 <= bytes.count {
            let header = bytes[offset..<offset + 512]
            // Two zero blocks end the archive; one is enough to stop.
            if header.allSatisfy({ $0 == 0 }) { break }
            guard let size = octal(header, from: 124, length: 12) else { throw GitHubSubmitError.unreadable }
            let dataStart = offset + 512
            let dataEnd = dataStart + size
            guard dataEnd <= bytes.count else { throw GitHubSubmitError.unreadable }
            let body = bytes[dataStart..<dataEnd]
            offset = dataStart + (size + 511) / 512 * 512

            switch header[header.startIndex + 156] {
            case UInt8(ascii: "x"):
                pendingPath = paxPath(body) ?? pendingPath
                continue
            case UInt8(ascii: "L"):
                pendingPath = string(body)
                continue
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                let name = pendingPath ?? ustarName(header)
                pendingPath = nil
                // A name that is not UTF-8 cannot become a file name here.
                guard let name, let path = strippedPath(name) else { continue }
                total += size
                guard total <= maxFileBytes else { throw GitHubSubmitError.tooLarge }
                entries.append(Entry(path: path, data: Data(body)))
            default:
                // Directories are implied by their files. Links, devices and the
                // pax global header (`g`) are dropped.
                pendingPath = nil
            }
        }
        return entries
    }

    /// `name` without its first component, or nil when nothing is left or a
    /// component could escape the workspace.
    static func strippedPath(_ name: String) -> String? {
        let components = name.split(separator: "/", omittingEmptySubsequences: true).dropFirst()
        guard !name.hasPrefix("/"), !components.isEmpty,
            components.allSatisfy({ $0 != "." && $0 != ".." })
        else { return nil }
        return components.joined(separator: "/")
    }

    // MARK: - Header fields

    /// A NUL-terminated field as UTF-8, or nil when it is not UTF-8.
    private static func string(_ field: ArraySlice<UInt8>) -> String? {
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(bytes: field[field.startIndex..<end], encoding: .utf8)
    }

    private static func octal(_ header: ArraySlice<UInt8>, from start: Int, length: Int) -> Int? {
        let field = header[(header.startIndex + start)..<(header.startIndex + start + length)]
        guard let text = string(field)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return text.isEmpty ? 0 : Int(text, radix: 8)
    }

    /// The ustar name: `prefix/name` when the prefix field is set.
    private static func ustarName(_ header: ArraySlice<UInt8>) -> String? {
        let base = header.startIndex
        guard let name = string(header[base..<base + 100]),
            let prefix = string(header[(base + 345)..<(base + 500)])
        else { return nil }
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    /// The `path` record of a pax extended header. Each record is
    /// `<length> <key>=<value>\n`, where the length counts the whole record.
    private static func paxPath(_ body: ArraySlice<UInt8>) -> String? {
        var index = body.startIndex
        while index < body.endIndex {
            guard let space = body[index...].firstIndex(of: UInt8(ascii: " ")),
                let lengthText = String(bytes: body[index..<space], encoding: .utf8),
                let length = Int(lengthText),
                length > space - index, index + length <= body.endIndex,
                let record = String(bytes: body[(space + 1)..<(index + length - 1)], encoding: .utf8)
            else { return nil }
            if record.hasPrefix("path=") { return String(record.dropFirst("path=".count)) }
            index += length
        }
        return nil
    }
}
