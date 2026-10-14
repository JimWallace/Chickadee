// APIServer/Middleware/PrecompressedAssetMiddleware.swift
//
// Serves the brotli copy of a large kernel file when the browser accepts it.
//
// The image build writes `<file>.br` beside each large `.wasm`, `.js` and `.so`
// file under the vendored xeus tree (the `kernel-assets` stage of the
// Dockerfile). Each copy keeps the mtime of its original, so its ETag is as
// stable across deploys as the original's. Compressing once at build time
// replaces a gzip of up to 27 MB per request, and brotli is 13-28% smaller
// than gzip -9 on these files.
//
// Every other case falls through to the next middleware, which serves the
// file as before: a client that does not accept br, a Range request (its
// Content-Range counts identity bytes), a path outside the tree, or a file with
// no `.br` copy (a checkout run without the image build has none).
//
// Registered just OUTSIDE FileMiddleware and KernelLibraryCompressionMiddleware.
// It returns without calling next, so the response is not compressed again,
// and the cache and isolation middlewares registered before it still decorate
// it on the way back.

import Vapor

struct PrecompressedAssetMiddleware: AsyncMiddleware {
    static let treePrefix = "/jupyterlite/xeus/"

    private let publicDirectory: String

    init(publicDirectory: String) {
        self.publicDirectory = publicDirectory.hasSuffix("/") ? publicDirectory : publicDirectory + "/"
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .GET || request.method == .HEAD,
            request.headers.first(name: .range) == nil,
            Self.acceptsBrotli(request.headers[.acceptEncoding]),
            let path = request.url.path.removingPercentEncoding,
            path.hasPrefix(Self.treePrefix),
            !path.contains(".."),
            // A NUL survives percent-decoding, and the file APIs stop at it:
            // `x.wasm%00` would find `x.wasm.br` but stream `x.wasm` as br.
            !path.contains("\0")
        else {
            return try await next.respond(to: request)
        }

        let compressedPath = publicDirectory + path.dropFirst() + ".br"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: compressedPath, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return try await next.respond(to: request)
        }

        let fileExtension = path.split(separator: ".").last.map(String.init) ?? ""
        let mediaType = HTTPMediaType.fileExtension(fileExtension) ?? .binary
        let response = try await request.fileio.asyncStreamFile(at: compressedPath, mediaType: mediaType)
        response.headers.replaceOrAdd(name: .contentEncoding, value: "br")
        response.headers.add(name: .vary, value: "Accept-Encoding")
        // The body is already compressed: the server must not compress it again.
        response.headers.responseCompression = .disable
        return response
    }

    /// True when the Accept-Encoding values name `br` with a non-zero quality.
    static func acceptsBrotli(_ values: [String]) -> Bool {
        values
            .flatMap { $0.split(separator: ",") }
            .contains { entry in
                let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.first?.lowercased() == "br" else { return false }
                let quality = parts.dropFirst()
                    .first { $0.lowercased().hasPrefix("q=") }
                    .flatMap { Double($0.dropFirst(2)) }
                return (quality ?? 1) > 0
            }
    }
}
