// APIServer/Routes/JupyterLiteContentsRoutes.swift
//
// Authenticated compatibility routes for JupyterLite's contents API.
// JupyterLite resolves API base paths differently across app entrypoints
// (`/jupyterlite/lab`, `/jupyterlite/notebooks`, or root), so we expose aliases
// for all expected URL shapes.

import Core
import Fluent
import Foundation
import Vapor

struct JupyterLiteContentsRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("jupyterlite", "api", "contents", use: contentsRoot)
        routes.get("jupyterlite", "api", "contents", "**", use: contentsPath)

        routes.get("api", "contents", use: contentsRoot)
        routes.get("api", "contents", "**", use: contentsPath)

        routes.get("lab", "api", "contents", use: contentsRoot)
        routes.get("lab", "api", "contents", "**", use: contentsPath)

        routes.get("notebooks", "api", "contents", use: contentsRoot)
        routes.get("notebooks", "api", "contents", "**", use: contentsPath)

        routes.get("jupyterlite", "lab", "api", "contents", use: contentsRoot)
        routes.get("jupyterlite", "lab", "api", "contents", "**", use: contentsPath)
        routes.get("jupyterlite", "notebooks", "api", "contents", use: contentsRoot)
        routes.get("jupyterlite", "notebooks", "api", "contents", "**", use: contentsPath)

        bootWriteRoutes(routes)
    }

    @Sendable
    func contentsRoot(req: Request) async throws -> Response {
        try await contentsResponse(req: req, relativePath: "")
    }

    @Sendable
    func contentsPath(req: Request) async throws -> Response {
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        // `<file>/checkpoints` is the server drive's checkpoint list (the write
        // half, JupyterLiteContentsRoutes+Write.swift). A catch-all route must
        // be last, so the suffix is matched here.
        if let filePath = checkpointedFile(req: req, relativePath: relPath) {
            return try await listCheckpoints(req: req, filePath: filePath)
        }
        return try await contentsResponse(req: req, relativePath: relPath)
    }

    private func contentsResponse(req: Request, relativePath: String) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        // The JupyterLite virtual filesystem is deployment-wide (not course-
        // scoped): course staff (TA+ in a course that is not archived, or
        // admin) get the full authoring tree, everyone else is scoped to their
        // own `users/<id>` folder (#417 Slice G — was the global
        // `caller.isInstructor`). A past-term TA is a student here (#2663).
        // Inside `users/`, staff reach another user's folder only through
        // `mayReadUserFile`: course staff of that setup's course (#2895).
        let isStaff = try await isStaffAnywhere(caller, includingArchived: false, db: req.db)
        let fm = FileManager.default
        let baseDir = req.application.directory.publicDirectory + "jupyterlite/files/"
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let baseURL = URL(fileURLWithPath: baseDir, isDirectory: true).standardizedFileURL

        // The kernel's file system walks to the notebook's folder one level at a
        // time, so it reads `users` before `users/<id>`. A student who may not
        // read the tree gets a `users` that lists only their own folder; a 403
        // here leaves the kernel's working directory at the drive root (#469).
        //
        // The drive root is read the same way, by `os.listdir('/drive')`: a
        // student gets a root whose one child is `users`. (The IndexedDB drive
        // reads the root as `all.json`, which still answers with the student's
        // own folder below.)
        if !isStaff, let userRoot = try userRootPath(for: caller, isStaff: false) {
            let requested = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let includeContent = req.query[String.self, at: "content"] == "1"
            if requested == "users" {
                return try ownUsersDirectoryResponse(
                    baseURL: baseURL, userRoot: userRoot, fileManager: fm, includeContent: includeContent)
            }
            if requested.isEmpty {
                return try studentRootDirectoryResponse(
                    baseURL: baseURL, userRoot: userRoot, fileManager: fm, includeContent: includeContent)
            }
        }

        let cleanRel = try scopedRelativePath(for: caller, requested: relativePath, isStaff: isStaff)
        let targetURL = baseURL.appendingPathComponent(cleanRel).standardizedFileURL
        guard targetURL.path.hasPrefix(baseURL.path) else {
            throw AppError.forbidden(action: "open files outside your own folder")
        }
        if let userRoot = try userRootPath(for: caller, isStaff: isStaff) {
            let userRootURL = baseURL.appendingPathComponent(userRoot, isDirectory: true).standardizedFileURL
            let withinUserRoot =
                targetURL.path == userRootURL.path
                || targetURL.path.hasPrefix(userRootURL.path + "/")
            guard withinUserRoot else {
                throw AppError.forbidden(action: "open files outside your own folder")
            }
        } else {
            // Staff see the authoring tree, but another user's folder only as
            // `mayReadUserFile` allows (#2895). The segments come from the
            // standardized target, so `shared/../users/…` is caught too.
            let resolved = targetURL.path.dropFirst(baseURL.path.count)
                .split(separator: "/", omittingEmptySubsequences: true)
            // Without case: a case-insensitive filesystem serves `Users/` too.
            if resolved.first?.lowercased() == "users" {
                let owner = resolved.count >= 2 && resolved[1] != "all.json" ? String(resolved[1]) : nil
                let setupID = resolved.count >= 3 && resolved[2] != "all.json" ? String(resolved[2]) : nil
                guard try await mayReadUserFile(caller, owner: owner, setupID: setupID, db: req.db) else {
                    throw AppError.forbidden(action: "open another user's files")
                }
            }
        }

        // JupyterLite 0.7 fetches directory manifests from
        // /api/contents/<dir>/all.json before opening files.
        if cleanRel == "all.json" || cleanRel.hasSuffix("/all.json") {
            let directoryRel: String
            if cleanRel == "all.json" {
                directoryRel = ""
            } else {
                directoryRel = String(cleanRel.dropLast("/all.json".count))
            }
            return try directoryResponse(
                baseURL: baseURL,
                directoryRelativePath: directoryRel,
                fileManager: fm,
                includeContent: true
            )
        }

        let wantsContent = req.query[String.self, at: "content"] == "1"

        if cleanRel.isEmpty || isDirectory(url: targetURL) {
            return try directoryResponse(
                baseURL: baseURL,
                directoryRelativePath: cleanRel,
                fileManager: fm,
                includeContent: wantsContent
            )
        }

        guard fm.fileExists(atPath: targetURL.path) else {
            throw AppError.notFound(resource: "File")
        }

        let attributes = attributesForItem(url: targetURL, fileManager: fm)
        // The editor's contents endpoint fires repeatedly while a student
        // works; notebooks and materialized datasets can be large. Thread
        // pool, not the request thread (#1156). The content is built there
        // too: checking that a notebook parses, or base64-encoding a dataset,
        // takes time in proportion to the file.
        let isNotebook = targetURL.pathExtension.lowercased() == "ipynb"
        let (fileData, (content, format, mimetype)) = try await runBlocking {
            () throws -> (Data, (JupyterContentsModel.Content, String, String)) in
            let fileData = try Data(contentsOf: targetURL)
            return (fileData, Self.contentModel(of: fileData, wantsContent: wantsContent, isNotebook: isNotebook))
        }

        return try jsonResponse(
            JupyterContentsModel(
                name: targetURL.lastPathComponent,
                path: cleanRel,
                lastModified: isoDate(asDate(attributes[.modificationDate])),
                created: isoDate(asDate(attributes[.creationDate])),
                content: content,
                format: format,
                mimetype: mimetype,
                size: fileData.count,
                writable: try await mayWrite(req: req, caller: caller, relativePath: cleanRel, url: targetURL),
                type: isNotebook ? "notebook" : "file"
            ))
    }

    /// The `writable` of a file's model: whether the write routes would accept a
    /// save of it from this caller. JupyterLab opens a file it may not write
    /// read-only, so a staff member reading a student's copy, a support file, a
    /// dataset or a `view-`/`preview-` record gets no autosave that the server
    /// would refuse (#469).
    private func mayWrite(req: Request, caller: APIUser, relativePath: String, url: URL) async throws -> Bool {
        guard !isSymlink(url: url), let userRoot = try userRootPath(for: caller, isStaff: false),
            relativePath.hasPrefix(userRoot + "/")
        else { return false }
        let parts = relativePath.split(separator: "/", maxSplits: 3).map(String.init)
        guard parts.count == 4 else { return true }
        let protected = try await WorkingCopyProtectedFiles.paths(
            setupID: parts[2], on: req.db, application: req.application)
        return !WorkingCopyProtectedFiles.touchesProtected(parts[3], in: protected)
    }

    /// The `content`, `format` and `mimetype` of a file's model.
    private static func contentModel(
        of fileData: Data, wantsContent: Bool, isNotebook: Bool
    ) -> (JupyterContentsModel.Content, String, String) {
        guard wantsContent else {
            return (.none, "json", isNotebook ? "application/x-ipynb+json" : "application/octet-stream")
        }
        if let json = JupyterContentsModel.jsonContent(fileData) {
            return (json, "json", isNotebook ? "application/x-ipynb+json" : "application/json")
        }
        if let text = String(data: fileData, encoding: .utf8) {
            return (.text(text), "text", "text/plain")
        }
        return (.base64(fileData.base64EncodedString()), "base64", "application/octet-stream")
    }

    private func directoryResponse(
        baseURL: URL,
        directoryRelativePath: String,
        fileManager: FileManager,
        includeContent: Bool
    ) throws -> Response {
        let cleanDir = directoryRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directoryURL =
            cleanDir.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(cleanDir).standardizedFileURL
        guard directoryURL.path.hasPrefix(baseURL.path) else {
            throw AppError.forbidden(action: "open files outside your own folder")
        }
        guard fileManager.fileExists(atPath: directoryURL.path), isDirectory(url: directoryURL) else {
            throw AppError.notFound(resource: "Folder")
        }

        let attributes = attributesForItem(url: directoryURL, fileManager: fileManager)
        let children = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .sorted(by: {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            })

        let childModels = children.map { child in
            let childAttributes = attributesForItem(url: child, fileManager: fileManager)
            let childPath = child.standardizedFileURL.path
                .replacingOccurrences(of: baseURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isDir = isDirectory(url: child)
            let isNotebook = child.pathExtension.lowercased() == "ipynb"
            return JupyterContentsModel(
                name: child.lastPathComponent,
                path: childPath,
                lastModified: isoDate(asDate(childAttributes[.modificationDate])),
                created: isoDate(asDate(childAttributes[.creationDate])),
                content: .none,
                format: "json",
                mimetype: isDir
                    ? "application/json" : (isNotebook ? "application/x-ipynb+json" : "application/octet-stream"),
                size: isDir ? 0 : ((childAttributes[.size] as? NSNumber)?.intValue ?? 0),
                writable: isDir ? true : !isSymlink(url: child),
                type: isDir ? "directory" : (isNotebook ? "notebook" : "file")
            )
        }

        return try jsonResponse(
            JupyterContentsModel(
                name: cleanDir.isEmpty ? "" : directoryURL.lastPathComponent,
                path: cleanDir,
                lastModified: isoDate(asDate(attributes[.modificationDate])),
                created: isoDate(asDate(attributes[.creationDate])),
                content: includeContent ? .children(childModels) : .none,
                format: "json",
                mimetype: "application/json",
                size: 0,
                writable: true,
                type: "directory"
            ))
    }

    /// `users` as a student sees it: a directory whose one child is their own
    /// folder. Nothing about any other user's folder is read or returned.
    private func ownUsersDirectoryResponse(
        baseURL: URL, userRoot: String, fileManager: FileManager, includeContent: Bool
    ) throws -> Response {
        let rootURL = baseURL.appendingPathComponent(userRoot, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let attributes = attributesForItem(url: rootURL, fileManager: fileManager)
        let modified = isoDate(asDate(attributes[.modificationDate]))
        let created = isoDate(asDate(attributes[.creationDate]))
        let own = JupyterContentsModel(
            name: rootURL.lastPathComponent, path: userRoot, lastModified: modified, created: created,
            content: .none, format: "json", mimetype: "application/json", size: 0, writable: true,
            type: "directory")
        return try jsonResponse(
            JupyterContentsModel(
                name: "users", path: "users", lastModified: modified, created: created,
                content: includeContent ? .children([own]) : .none, format: "json",
                mimetype: "application/json", size: 0, writable: false, type: "directory"))
    }

    /// The drive root as a student sees it: a directory whose one child is
    /// `users`, which in turn lists only their own folder.
    private func studentRootDirectoryResponse(
        baseURL: URL, userRoot: String, fileManager: FileManager, includeContent: Bool
    ) throws -> Response {
        let rootURL = baseURL.appendingPathComponent(userRoot, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let attributes = attributesForItem(url: rootURL, fileManager: fileManager)
        let modified = isoDate(asDate(attributes[.modificationDate]))
        let created = isoDate(asDate(attributes[.creationDate]))
        let users = JupyterContentsModel(
            name: "users", path: "users", lastModified: modified, created: created,
            content: .none, format: "json", mimetype: "application/json", size: 0, writable: false,
            type: "directory")
        return try jsonResponse(
            JupyterContentsModel(
                name: "", path: "", lastModified: modified, created: created,
                content: includeContent ? .children([users]) : .none, format: "json",
                mimetype: "application/json", size: 0, writable: false, type: "directory"))
    }

    func jsonResponse(_ model: JupyterContentsModel) throws -> Response {
        Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: try model.jsonData())
        )
    }

    private func isDirectory(url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Returns true if `url` is a symbolic link (used to mark support files read-only).
    func isSymlink(url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func attributesForItem(url: URL, fileManager: FileManager) -> [FileAttributeKey: Any] {
        (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
    }

    private func asDate(_ any: Any?) -> Date {
        (any as? Date) ?? Date()
    }

    func isoDate(_ date: Date) -> String {
        iso8601String(date)
    }

    func userRootPath(for caller: APIUser, isStaff: Bool) throws -> String? {
        if isStaff {
            return nil
        }
        guard let userID = caller.id else {
            throw AppError.unauthenticated
        }
        return "users/\(userID.uuidString.lowercased())"
    }

    private func scopedRelativePath(
        for caller: APIUser, requested: String, isStaff: Bool
    ) throws
        -> String
    {
        let clean = requested.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if isStaff {
            return clean
        }

        guard let userRoot = try userRootPath(for: caller, isStaff: isStaff) else {
            return clean
        }

        if clean.isEmpty {
            return userRoot
        }
        if clean == "all.json" {
            return "\(userRoot)/all.json"
        }
        if clean == userRoot || clean.hasPrefix(userRoot + "/") {
            return clean
        }
        throw AppError.forbidden(action: "open files outside your own folder")
    }
}
