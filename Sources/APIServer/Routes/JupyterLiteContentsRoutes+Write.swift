// APIServer/Routes/JupyterLiteContentsRoutes+Write.swift
//
// The write half of the Jupyter contents API, for the server-backed editor
// drive (spike for #469; `Tools/jupyterlite/chickadee-extension/src/serverDrive.ts`).
//
// JupyterLab's REST `Drive` calls, while a notebook is open and saved:
//
//   GET  /jupyterlite/api/contents/<path>               (the read routes)
//   PUT  /jupyterlite/api/contents/<path>               save
//   GET  /jupyterlite/api/contents/<path>/checkpoints   list, on open
//   POST /jupyterlite/api/contents/<path>/checkpoints   create, after a save
//
// and the kernel's file system (DriveFS, answered on the main thread through
// the same contents manager) adds, for `os.mkdir`:
//
//   POST  /jupyterlite/api/contents/<dir>    {type: "directory"}: new untitled
//   PATCH /jupyterlite/api/contents/<path>   {path}: rename
//
// Only the `/jupyterlite/` prefix is routed: the drive's base URL is the
// JupyterLite root. Checkpoints are stubs. The one "checkpoint" is the file as
// it is now, and restoring or deleting it changes nothing: a revert to a
// checkpoint is out of the spike's scope.
//
// Every caller, staff included, writes only under their own `users/<id>/`
// folder. The read routes let staff read the whole tree; a write there could
// overwrite another person's working copy. A support file or dataset in a
// working copy is a symlink into a shared directory, so a write is refused when
// the target is a symlink or its resolved parent leaves the caller's folder.
//
// The files the assignment provides (its datasets and support files) and the
// read-only submission records are refused by name (WorkingCopyProtectedFiles):
// a student's change to one would persist, and no reset would repair it.
//
// Conflicts are JupyterLab's: before a save it compares the file's
// `last_modified` with its own last save, so a reset done on the server since
// then raises its "File changed" dialog. A save therefore answers with the
// file's real mtime after the write.

import Fluent
import Foundation
import NIOFoundationCompat
import Vapor

extension JupyterLiteContentsRoutes {
    /// The largest body a save accepts. A notebook with embedded plot output
    /// can reach a few megabytes; the dataset routes allow 17 MB.
    static let maxSaveBodySize: ByteCount = "17mb"

    /// The id of the one stub checkpoint.
    static let checkpointID = "checkpoint"

    func bootWriteRoutes(_ routes: any RoutesBuilder) {
        routes.on(
            .PUT, "jupyterlite", "api", "contents", "**",
            body: .collect(maxSize: Self.maxSaveBodySize), use: saveContents)
        routes.post("jupyterlite", "api", "contents", "**", use: postContents)
        routes.patch("jupyterlite", "api", "contents", "**", use: renameContents)
        routes.delete("jupyterlite", "api", "contents", "**", use: deleteContents)
    }

    // MARK: - Handlers

    @Sendable
    func saveContents(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        let target = try writableTarget(req: req, caller: caller, relativePath: relPath)
        try await refuseProtected(req: req, target, movingContents: false)
        let save = try Self.decodeSave(req.body.data)

        try await runBlocking {
            let fm = FileManager.default
            switch save {
            case .directory:
                let existing = (try? fm.attributesOfItem(atPath: target.url.path))?[.type] as? FileAttributeType
                guard existing == nil || existing == .typeDirectory else {
                    throw AppError.conflict(reason: "\(target.relativePath) is a file.")
                }
                try fm.createDirectory(at: target.url, withIntermediateDirectories: true)
            case .bytes(let data):
                try fm.createDirectory(
                    at: target.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target.url, options: .atomic)
            }
        }
        req.logger.info(
            "jupyterlite_contents_save",
            metadata: ["path": .string(target.relativePath), "bytes": .stringConvertible(save.byteCount)])
        return try jsonResponse(model(of: target, isDirectory: save.isDirectory))
    }

    /// Lists the stub checkpoint (`GET <path>/checkpoints`). Called by the read
    /// route for a path that ends in `/checkpoints`.
    func listCheckpoints(req: Request, filePath: String) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let target = try writableTarget(req: req, caller: caller, relativePath: filePath)
        let body = try JSONEncoder().encode([checkpoint(of: target)])
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    @Sendable
    func postContents(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        guard let filePath = checkpointedFile(req: req, relativePath: relPath) else {
            return try await createUntitledDirectory(req: req, caller: caller, parentPath: relPath)
        }
        let target = try writableTarget(req: req, caller: caller, relativePath: filePath)
        let body = try JSONEncoder().encode(checkpoint(of: target))
        return Response(status: .created, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }

    /// `POST <dir>` with `{type: "directory"}`: the contents manager's
    /// `newUntitled`. The kernel's file system makes a directory this way and
    /// then renames it (`os.mkdir`). Untitled files and notebooks (the file
    /// browser's "New") are not supported: the editor opens one notebook.
    private func createUntitledDirectory(req: Request, caller: APIUser, parentPath: String) async throws -> Response {
        let object = req.body.data.flatMap { try? JSONSerialization.jsonObject(with: Data(buffer: $0)) }
        guard (object as? [String: Any])?["type"] as? String == "directory" else {
            throw AppError.methodNotAllowed(reason: "Only a new directory can be created.")
        }
        let parent = parentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // The probe target only proves the parent is the caller's.
        let probe = try writableTarget(req: req, caller: caller, relativePath: parent + "/Untitled Folder")
        let parentURL = probe.url.deletingLastPathComponent()
        let created: WritableTarget = try await runBlocking {
            let fm = FileManager.default
            for index in 0..<100 {
                let name = index == 0 ? "Untitled Folder" : "Untitled Folder \(index)"
                let url = parentURL.appendingPathComponent(name, isDirectory: true)
                if (try? fm.attributesOfItem(atPath: url.path)) == nil {
                    try fm.createDirectory(at: url, withIntermediateDirectories: false)
                    return WritableTarget(relativePath: parent + "/" + name, url: url)
                }
            }
            throw AppError.conflict(reason: "Too many untitled folders.")
        }
        let response = try jsonResponse(model(of: created, isDirectory: true))
        response.status = .created
        return response
    }

    /// `PATCH <path>` with `{path: <new path>}`: rename, inside the caller's
    /// own folder only, never over an existing item.
    @Sendable
    func renameContents(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        let object = req.body.data.flatMap { try? JSONSerialization.jsonObject(with: Data(buffer: $0)) }
        guard let newPath = (object as? [String: Any])?["path"] as? String else {
            throw AppError.badRequest(reason: "A rename needs the new path.")
        }
        let source = try writableTarget(req: req, caller: caller, relativePath: relPath)
        let destination = try writableTarget(req: req, caller: caller, relativePath: newPath)
        try await refuseProtected(req: req, source, movingContents: true)
        try await refuseProtected(req: req, destination, movingContents: true)
        let isDirectory: Bool = try await runBlocking {
            let fm = FileManager.default
            guard let attributes = try? fm.attributesOfItem(atPath: source.url.path) else {
                throw AppError.notFound(resource: "File")
            }
            guard (try? fm.attributesOfItem(atPath: destination.url.path)) == nil else {
                throw AppError.conflict(reason: "\(destination.relativePath) already exists.")
            }
            guard (try? fm.attributesOfItem(atPath: destination.url.deletingLastPathComponent().path)) != nil else {
                throw AppError.notFound(resource: "Folder")
            }
            try fm.moveItem(at: source.url, to: destination.url)
            return attributes[.type] as? FileAttributeType == .typeDirectory
        }
        return try jsonResponse(model(of: destination, isDirectory: isDirectory))
    }

    /// Restoring or deleting the stub checkpoint changes nothing.
    @Sendable
    func deleteContents(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        let parts = relPath.split(separator: "/")
        let checkpointsPath = parts.dropLast().joined(separator: "/")
        guard parts.count > 2, let filePath = checkpointedFile(req: req, relativePath: checkpointsPath) else {
            throw AppError.methodNotAllowed(reason: "Deleting files is not supported.")
        }
        _ = try writableTarget(req: req, caller: caller, relativePath: filePath)
        return Response(status: .noContent)
    }

    /// The file whose checkpoints `relativePath` (`<file>/checkpoints`) names,
    /// or nil when it is not a checkpoint path: it does not end in
    /// `/checkpoints`, a real item has that path (a student's own
    /// `checkpoints/` folder), or the file before it is not a regular file.
    func checkpointedFile(req: Request, relativePath: String) -> String? {
        let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard clean.hasSuffix("/checkpoints") else { return nil }
        let filePath = String(clean.dropLast("/checkpoints".count))
        let base = req.application.directory.publicDirectory + "jupyterlite/files/"
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: base + clean)) == nil,
            let type = (try? fm.attributesOfItem(atPath: base + filePath))?[.type] as? FileAttributeType,
            type == .typeRegular
        else { return nil }
        return filePath
    }

    // MARK: - Scope

    /// Refuses a write to a file only the server writes (WorkingCopyProtectedFiles):
    /// a delivered dataset or support file, or a submission record. With
    /// `movingContents` (a rename), also refuses the setup folder itself and a
    /// folder that holds a protected file.
    func refuseProtected(req: Request, _ target: WritableTarget, movingContents: Bool) async throws {
        // users/<id>/<setupID>/<path inside the working copy>
        let parts = target.relativePath.split(separator: "/", maxSplits: 3).map(String.init)
        guard parts.count >= 3 else { return }
        guard parts.count == 4 else {
            if movingContents { throw AppError.forbidden(action: "rename an assignment folder") }
            return
        }
        let protected = try await WorkingCopyProtectedFiles.paths(
            setupID: parts[2], on: req.db, application: req.application)
        let inside = parts[3]
        if WorkingCopyProtectedFiles.isProtected(inside, in: protected)
            || (movingContents && WorkingCopyProtectedFiles.holdsProtected(inside, in: protected))
        {
            throw AppError.forbidden(action: "change a file the assignment provides (\(inside))")
        }
    }

    /// A path the caller may write, resolved under the JupyterLite files root.
    struct WritableTarget: Sendable {
        let relativePath: String
        let url: URL
    }

    /// Resolves `relativePath` for a write by `caller`, or throws `forbidden`.
    func writableTarget(req: Request, caller: APIUser, relativePath: String) throws -> WritableTarget {
        let clean = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let userRoot = try userRootPath(for: caller, isStaff: false) else {
            throw AppError.unauthenticated
        }
        let components = clean.split(separator: "/", omittingEmptySubsequences: false)
        guard clean.hasPrefix(userRoot + "/"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw AppError.forbidden(action: "save files outside your own folder")
        }

        let baseURL = URL(
            fileURLWithPath: req.application.directory.publicDirectory + "jupyterlite/files/", isDirectory: true)
        let targetURL = baseURL.appendingPathComponent(clean).standardizedFileURL
        let rootURL = baseURL.appendingPathComponent(userRoot, isDirectory: true).resolvingSymlinksInPath()
        let parentURL = targetURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let withinRoot = parentURL.path == rootURL.path || parentURL.path.hasPrefix(rootURL.path + "/")
        guard withinRoot, !isSymlink(url: targetURL) else {
            throw AppError.forbidden(action: "save over a shared file")
        }
        return WritableTarget(relativePath: clean, url: targetURL)
    }

    // MARK: - Models

    private func model(of target: WritableTarget, isDirectory: Bool) throws -> JupyterContentsModel {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: target.url.path)) ?? [:]
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let created = (attributes[.creationDate] as? Date) ?? modified
        let isNotebook = target.url.pathExtension.lowercased() == "ipynb"
        return JupyterContentsModel(
            name: target.url.lastPathComponent,
            path: target.relativePath,
            lastModified: isoDate(modified),
            created: isoDate(created),
            content: .none,
            format: "json",
            mimetype: isDirectory
                ? "application/json" : (isNotebook ? "application/x-ipynb+json" : "application/octet-stream"),
            size: isDirectory ? 0 : ((attributes[.size] as? NSNumber)?.intValue ?? 0),
            writable: true,
            type: isDirectory ? "directory" : (isNotebook ? "notebook" : "file")
        )
    }

    private struct Checkpoint: Encodable {
        let id: String
        let lastModified: String

        enum CodingKeys: String, CodingKey {
            case id
            case lastModified = "last_modified"
        }
    }

    private func checkpoint(of target: WritableTarget) -> Checkpoint {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: target.url.path)) ?? [:]
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        return Checkpoint(id: Self.checkpointID, lastModified: isoDate(modified))
    }

    // MARK: - Body

    /// What a save writes.
    enum SaveBody: Sendable {
        case directory
        case bytes(Data)

        var isDirectory: Bool {
            if case .directory = self { return true }
            return false
        }

        var byteCount: Int {
            if case .bytes(let data) = self { return data.count }
            return 0
        }
    }

    /// Decodes a contents-API save body: `{type, format, content}`.
    ///
    /// - `directory`: no content.
    /// - `notebook`, or `format == "json"`: `content` is a JSON value, written
    ///   with sorted keys so that a save that changes nothing changes no bytes.
    /// - `format == "text"`: `content` is a string, written as UTF-8.
    /// - `format == "base64"`: `content` is a base64 string.
    static func decodeSave(_ body: ByteBuffer?) throws -> SaveBody {
        guard let body,
            let object = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
            let type = object["type"] as? String
        else {
            throw AppError.badRequest(reason: "The save body is not a contents model.")
        }
        if type == "directory" {
            return .directory
        }
        // The kernel's file system creates a file (`mknod`) as `{type: "file"}`
        // with no content: an empty file.
        guard object["content"] != nil, !(object["content"] is NSNull) else {
            return .bytes(Data())
        }
        let format = object["format"] as? String ?? (type == "notebook" ? "json" : "text")
        switch format {
        case "json":
            guard let content = object["content"], content is [String: Any] || content is [Any] else {
                throw AppError.badRequest(reason: "A JSON save needs an object or array as its content.")
            }
            let data = try JSONSerialization.data(
                withJSONObject: content, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            return .bytes(data)
        case "text":
            guard let text = object["content"] as? String else {
                throw AppError.badRequest(reason: "A text save needs a string as its content.")
            }
            return .bytes(Data(text.utf8))
        case "base64":
            guard let text = object["content"] as? String,
                let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
            else {
                throw AppError.badRequest(reason: "A base64 save needs base64 content.")
            }
            return .bytes(data)
        default:
            throw AppError.badRequest(reason: "Unknown save format \(format).")
        }
    }
}
