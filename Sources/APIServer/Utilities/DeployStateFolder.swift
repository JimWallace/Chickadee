// APIServer/Utilities/DeployStateFolder.swift
//
// The app's side of the deploy daemon's state folder (docs/release-gate.md).
//
// The daemon (deploy/chickadee-deployer.sh) owns the folder. The app reads it
// through a read-only mount at `/deploy-state`: status.json, history.jsonl,
// pending-notes.json and prerelease-notes.json. It may write one place only, `requests/`, which
// bluegreen-deploy.sh mounts read-write over the read-only folder. A request
// is a request, not a command: the daemon validates each one, accepts only
// approve-the-held-release (or the offered pre-release), mode, pause and resume, and records every request
// in its history. Rollback stays a host action.
//
// Pure file I/O over a directory path, with no Vapor and no database, so it
// lives in Utilities.

import Foundation

struct DeployStateFolder: Sendable {
    let directory: String

    private var root: URL { URL(fileURLWithPath: directory) }
    var requestsFolder: URL { root.appendingPathComponent("requests") }

    /// The daemon's status, or nil when there is none or it cannot be parsed.
    func status() -> DeployStatusFile? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("status.json")) else { return nil }
        return try? JSONDecoder().decode(DeployStatusFile.self, from: data)
    }

    /// The held release's notes, or nil when nothing is held.
    func pendingNotes() -> DeployPendingNotes? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("pending-notes.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(DeployPendingNotes.self, from: data)
    }

    /// The offered pre-release's notes (prerelease-notes.json), or nil.
    func prereleaseNotes() -> DeployPendingNotes? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("prerelease-notes.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(DeployPendingNotes.self, from: data)
    }

    /// The last `limit` history lines, newest first. A line that does not
    /// parse is skipped.
    func history(limit: Int) -> [DeployHistoryRecord] {
        guard
            let text = try? String(contentsOf: root.appendingPathComponent("history.jsonl"), encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        let records = text.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(DeployHistoryRecord.self, from: Data($0.utf8))
        }
        return Array(records.suffix(max(limit, 0)).reversed())
    }

    /// The deploy mode the daemon reports, or its default when it reports none.
    func modeInForce() -> DeployMode {
        status()?.mode.flatMap(DeployMode.init(rawValue:)) ?? .daemonDefault
    }

    /// The requests the daemon has not read yet, oldest first. A file that
    /// does not parse as one of the four, or is not a small regular file, is
    /// skipped.
    func waitingRequests() -> [DeployRequest] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requestsFolder.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            // Only a regular file under the daemon's own 4 KB limit: a FIFO or
            // a symlink in this app-writable folder must not hang the page.
            let url = requestsFolder.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.size] as? Int ?? .max) <= 4096,
                let data = try? Data(contentsOf: url),
                let body = try? JSONDecoder().decode([String: String].self, from: data)
            else { return nil }
            return DeployRequest(body: body)
        }
    }

    /// Request files the daemon has not read yet. It reads them every poll.
    func waitingRequestCount() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: requestsFolder.path)) ?? []
        return names.count(where: { $0.hasSuffix(".json") })
    }

    /// Writes `request` as one new file in requests/. The file is written
    /// under a temporary name and renamed, because the daemon reads only
    /// names that end in .json. Returns the file name.
    @discardableResult
    func write(
        _ request: DeployRequest, user: String, at now: Date = Date()
    ) throws(DeployRequestWriteError) -> String {
        guard FileManager.default.fileExists(atPath: requestsFolder.path) else {
            throw .requestsFolderMissing
        }
        // Milliseconds first, so the names sort in the order they were sent.
        let stamp = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let name = "\(stamp)-\(UUID().uuidString.lowercased()).json"
        let temporary = requestsFolder.appendingPathComponent(name + ".tmp")
        let final = requestsFolder.appendingPathComponent(name)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: request.body(user: user, requestedAt: now), options: [.sortedKeys])
            try data.write(to: temporary)
            try FileManager.default.moveItem(at: temporary, to: final)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw .writeFailed
        }
        return name
    }

    /// True for a release tag of the form the daemon accepts, `vX.Y.Z` or a
    /// pre-release `vX.Y.Z-rc.N`.
    static func isReleaseTag(_ text: String) -> Bool {
        text.wholeMatch(of: releaseTagPattern) != nil
    }

    private static var releaseTagPattern: Regex<Substring> { /v[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?/ }
}
