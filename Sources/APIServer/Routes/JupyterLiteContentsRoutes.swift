// APIServer/Routes/JupyterLiteContentsRoutes.swift
//
// Public (unauthenticated) compatibility routes for JupyterLite's contents API.
// JupyterLite resolves API base paths differently across app entrypoints
// (`/jupyterlite/lab`, `/jupyterlite/notebooks`, or root), so we expose aliases
// for all expected URL shapes.

import Vapor
import Foundation

struct JupyterLiteContentsRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
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
    }

    @Sendable
    func contentsRoot(req: Request) async throws -> Response {
        try contentsResponse(req: req, relativePath: "")
    }

    @Sendable
    func contentsPath(req: Request) async throws -> Response {
        let relPath = req.parameters.getCatchall().joined(separator: "/")
        return try contentsResponse(req: req, relativePath: relPath)
    }

    private func contentsResponse(req: Request, relativePath: String) throws -> Response {
        let fm = FileManager.default
        let baseDir = req.application.directory.publicDirectory + "jupyterlite/files/"
        try fm.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let baseURL = URL(fileURLWithPath: baseDir, isDirectory: true).standardizedFileURL

        let cleanRel = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let targetURL = baseURL.appendingPathComponent(cleanRel).standardizedFileURL
        guard targetURL.path.hasPrefix(baseURL.path) else {
            throw Abort(.forbidden)
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
            throw Abort(.notFound)
        }

        let attributes = attributesForItem(url: targetURL, fileManager: fm)
        let fileData = try Data(contentsOf: targetURL)
        let isNotebook = targetURL.pathExtension.lowercased() == "ipynb"
        let (contentValue, format, mimetype): (Any, String, String) = {
            guard wantsContent else {
                return (NSNull(), "json", isNotebook ? "application/x-ipynb+json" : "application/octet-stream")
            }
            if let json = try? JSONSerialization.jsonObject(with: fileData) {
                return (json, "json", isNotebook ? "application/x-ipynb+json" : "application/json")
            }
            if let text = String(data: fileData, encoding: .utf8) {
                return (text, "text", "text/plain")
            }
            return (fileData.base64EncodedString(), "base64", "application/octet-stream")
        }()

        let model: [String: Any] = [
            "name": targetURL.lastPathComponent,
            "path": cleanRel,
            "last_modified": isoDate(asDate(attributes[.modificationDate])),
            "created": isoDate(asDate(attributes[.creationDate])),
            "content": contentValue,
            "format": format,
            "mimetype": mimetype,
            "size": fileData.count,
            "writable": true,
            "type": isNotebook ? "notebook" : "file"
        ]
        return try jsonResponse(model)
    }

    private func directoryResponse(
        baseURL: URL,
        directoryRelativePath: String,
        fileManager: FileManager,
        includeContent: Bool
    ) throws -> Response {
        let cleanDir = directoryRelativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let directoryURL = cleanDir.isEmpty
            ? baseURL
            : baseURL.appendingPathComponent(cleanDir).standardizedFileURL
        guard directoryURL.path.hasPrefix(baseURL.path) else {
            throw Abort(.forbidden)
        }
        guard fileManager.fileExists(atPath: directoryURL.path), isDirectory(url: directoryURL) else {
            throw Abort(.notFound)
        }

        let attributes = attributesForItem(url: directoryURL, fileManager: fileManager)
        let children = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending })

        let childModels: [[String: Any]] = children.map { child in
            let childAttributes = attributesForItem(url: child, fileManager: fileManager)
            let childPath = child.standardizedFileURL.path
                .replacingOccurrences(of: baseURL.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let isDir = isDirectory(url: child)
            let isNotebook = child.pathExtension.lowercased() == "ipynb"
            return [
                "name": child.lastPathComponent,
                "path": childPath,
                "last_modified": isoDate(asDate(childAttributes[.modificationDate])),
                "created": isoDate(asDate(childAttributes[.creationDate])),
                "content": NSNull(),
                "format": "json",
                "mimetype": isDir ? "application/json" : (isNotebook ? "application/x-ipynb+json" : "application/octet-stream"),
                "size": isDir ? 0 : ((childAttributes[.size] as? NSNumber)?.intValue ?? 0),
                "writable": true,
                "type": isDir ? "directory" : (isNotebook ? "notebook" : "file")
            ]
        }

        let model: [String: Any] = [
            "name": cleanDir.isEmpty ? "" : directoryURL.lastPathComponent,
            "path": cleanDir,
            "last_modified": isoDate(asDate(attributes[.modificationDate])),
            "created": isoDate(asDate(attributes[.creationDate])),
            "content": includeContent ? childModels : NSNull(),
            "format": "json",
            "mimetype": "application/json",
            "size": 0,
            "writable": true,
            "type": "directory"
        ]
        return try jsonResponse(model)
    }

    private func jsonResponse(_ model: [String: Any]) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: model)
        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    private func isDirectory(url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func attributesForItem(url: URL, fileManager: FileManager) -> [FileAttributeKey: Any] {
        (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
    }

    private func asDate(_ any: Any?) -> Date {
        (any as? Date) ?? Date()
    }

    private func isoDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
