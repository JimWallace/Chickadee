// APIServer/Services/AssignmentVersionBlobStore.swift
//
// Content-addressed byte storage for assignment version snapshots
// (docs/assignment-versioning.md).
//
// Blobs are keyed by the SHA-256 of their own bytes and stored at
// `{testSetupsDirectory}/versions/blobs/{first-2-hex}/{sha256}`. Writing the
// same bytes twice is a no-op, so a snapshot only ever costs the bytes that
// actually changed.
//
// Why per FILE rather than per zip: `/usr/bin/zip` embeds timestamps, so
// repacking byte-identical content yields a different archive every time —
// hashing whole archives would dedupe nothing at all, and "snapshot every edit,
// never delete" would become a disk-fill incident. Hashing entries means an
// untouched 3 MB dataset costs nothing across a 200-edit authoring session.
//
// Nothing here deletes. Reclamation happens only when a course is purged, as a
// separate sweep that drops blobs no surviving version references.

import Core
import Foundation

enum AssignmentVersionBlobError: Error, CustomStringConvertible {
    case invalidHash(String)
    case notFound(String)
    case writeFailed(hash: String, reason: String)

    var description: String {
        switch self {
        case .invalidHash(let hash):
            return "Not a SHA-256 hex digest: \(hash.prefix(80))"
        case .notFound(let hash):
            return "No stored blob for \(hash)"
        case .writeFailed(let hash, let reason):
            return "Could not store blob \(hash): \(reason)"
        }
    }
}

/// Reads and writes the content-addressed blobs backing version snapshots.
/// Immutable value type; safe to construct per call.
struct AssignmentVersionBlobStore: Sendable {
    /// `{testSetupsDirectory}/versions/blobs/`, with a trailing slash.
    let rootDirectory: String

    init(testSetupsDirectory: String) {
        let base =
            testSetupsDirectory.hasSuffix("/") ? testSetupsDirectory : testSetupsDirectory + "/"
        self.rootDirectory = base + "versions/blobs/"
    }

    // MARK: - Paths

    /// True iff `hash` is exactly 64 lowercase hex characters.
    ///
    /// Every path this type builds is derived from a hash, and hashes arrive
    /// from a database column. Validating the shape before it reaches the
    /// filesystem is what stops a malformed or tampered row from walking out of
    /// the blob directory with `../`.
    static func isValidHash(_ hash: String) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// On-disk location for `hash`. Throws rather than returning a path built
    /// from an unvalidated string.
    func path(for hash: String) throws -> String {
        guard Self.isValidHash(hash) else {
            throw AssignmentVersionBlobError.invalidHash(hash)
        }
        return rootDirectory + String(hash.prefix(2)) + "/" + hash
    }

    func exists(_ hash: String) -> Bool {
        guard let path = try? path(for: hash) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Writing

    /// Stores `data` and returns its hash. A no-op when the blob is already
    /// present — identical content is identical bytes, by construction.
    @discardableResult
    func put(_ data: Data) throws -> String {
        let hash = sha256HexDigest(data)
        try store(hash: hash) { destination in
            try data.write(to: destination)
        }
        return hash
    }

    /// Stores the file at `sourcePath` and returns its hash. The file is
    /// streamed for hashing (never fully resident), then copied — datasets in a
    /// setup zip can be hundreds of megabytes.
    @discardableResult
    func putFile(at sourcePath: String) throws -> String {
        guard let hash = sha256HexDigest(prefix: Data(), contentsOfFile: sourcePath) else {
            throw AssignmentVersionBlobError.writeFailed(
                hash: "?", reason: "could not read \(sourcePath)")
        }
        try store(hash: hash) { destination in
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: sourcePath), to: destination)
        }
        return hash
    }

    /// Writes a blob via `write`, into a temp file that is then atomically
    /// renamed into place. The rename is what makes a concurrent reader see
    /// either no blob or a complete one, never a half-written one — two
    /// requests snapshotting the same unchanged dataset race here routinely.
    private func store(hash: String, write: (URL) throws -> Void) throws {
        let finalPath = try path(for: hash)
        guard !FileManager.default.fileExists(atPath: finalPath) else { return }

        let directory = (finalPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw AssignmentVersionBlobError.writeFailed(hash: hash, reason: "\(error)")
        }

        let temp = URL(fileURLWithPath: directory + "/.tmp-\(UUID().uuidString)")
        do {
            try write(temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw AssignmentVersionBlobError.writeFailed(hash: hash, reason: "\(error)")
        }
        do {
            try FileManager.default.moveItem(at: temp, to: URL(fileURLWithPath: finalPath))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            // A rename losing to a concurrent writer of the SAME hash is a
            // success: the bytes are there and they are the bytes we wanted.
            guard FileManager.default.fileExists(atPath: finalPath) else {
                throw AssignmentVersionBlobError.writeFailed(hash: hash, reason: "\(error)")
            }
        }
    }

    // MARK: - Reading

    func read(_ hash: String) throws -> Data {
        let path = try path(for: hash)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AssignmentVersionBlobError.notFound(hash)
        }
        return data
    }

    /// Copies the blob to `destination`, creating intermediate directories.
    /// Used when rebuilding a setup directory from a snapshot's file map.
    func materialize(_ hash: String, to destination: URL) throws {
        let path = try path(for: hash)
        guard FileManager.default.fileExists(atPath: path) else {
            throw AssignmentVersionBlobError.notFound(hash)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
    }
}
