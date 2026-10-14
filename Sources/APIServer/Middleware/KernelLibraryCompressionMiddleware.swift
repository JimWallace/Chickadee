// APIServer/Middleware/KernelLibraryCompressionMiddleware.swift
//
// Turns on response compression for the shared libraries that a vendored xeus
// kernel loads at boot (`liboctave.so`, `liboctinterp.so`, `libR.so`, ...).
//
// Why: the server sends a `.so` file as `application/octet-stream`, which is
// not in Vapor's compressible allowlist (`.enabledForCompressibleTypes`) or in
// the `gzip_types` of either nginx config. So an Octave boot downloaded
// ~52 MB of libraries uncompressed, and an R boot ~11 MB. These libraries are
// emscripten side modules and compress about 4x (52 MB to ~13 MB).
//
// The override is set here, in the app, and not in nginx. The image carries
// it to every deployment, and nginx passes a body that is already gzipped
// through unchanged (`gzip_proxied any`).
//
// Registered just OUTSIDE FileMiddleware, which serves these files: a
// middleware registered after FileMiddleware never sees its responses.

import Vapor

struct KernelLibraryCompressionMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        // A full 200 GET only. The compressor keeps `Content-Range`, so a 206
        // would describe identity bytes under a gzip body. A HEAD would
        // advertise gzip next to an identity `Content-Length`.
        guard request.method == .GET, response.status == .ok,
            Self.isKernelSharedLibrary(path: request.url.path)
        else {
            return response
        }
        response.headers.responseCompression = .enable
        // The same URL now has two encodings, so a shared cache must key on
        // the request's Accept-Encoding.
        response.headers.add(name: .vary, value: "Accept-Encoding")
        return response
    }

    /// True for a shared library in the vendored xeus tree. That tree holds
    /// checked-in vendored bytes only, so compressing it exposes no secret.
    static func isKernelSharedLibrary(path: String) -> Bool {
        path.hasPrefix("/jupyterlite/xeus/") && path.hasSuffix(".so")
    }
}
