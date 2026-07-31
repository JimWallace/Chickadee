// APIServer/MCP/Tools/SupportFileURLFetcher.swift
//
// Server-side fetch of a support/data file referenced by URL, for the MCP
// `author_script(sourceUrl:)` path.  An agent often cannot faithfully inline a
// large data file (a CSV, a fixture) into a tool call, so it passes a URL and
// the server downloads the bytes instead.
//
// A server fetching a caller-supplied URL is a classic SSRF vector, so the
// fetch is guarded in depth (the caller is an authenticated instructor with
// content:write, but an account can be compromised and an agent can be
// prompt-injected, so we never trust the URL):
//
//   1. https only — no file://, ftp://, gopher://, data://.
//   2. No userinfo (`user:pass@`) — a common parser-confusion trick.
//   3. The host is resolved here and EVERY resulting IP is checked; the fetch is
//      refused if any address is loopback / private / link-local (incl. the
//      169.254.169.254 cloud-metadata range) / CGNAT / ULA / multicast /
//      reserved.  IPv4, IPv6, and IPv4-mapped/compatible forms are normalised
//      before the check, and obfuscated literals (octal/hex) are caught because
//      they resolve to a canonical numeric IP that is then classified.
//   4. Redirects are disallowed — a public URL that 302s to an internal address
//      is rejected, not followed.
//   5. The body is capped at `maxBytes`, enforced while streaming (Content-Length
//      can lie), and the whole request is bounded by a connect/read/overall
//      timeout (which also stops the fetch being used as an internal port
//      scanner via timing).
//
// One honest residual: AsyncHTTPClient does its own DNS and won't let us pin the
// address we just validated, so there is a theoretical DNS-rebinding TOCTOU
// window between our check and its connect.  Disallowing redirects (4) shrinks
// it; closing it entirely would require a host allowlist, which is deliberately
// not part of this design.
//
// `BlockedIPClassifier` is split out as a pure, network-free function so the
// security-critical range logic is exhaustively unit-tested without DNS.

import AsyncHTTPClient
import Foundation
import NIOCore
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Errors raised while fetching a support file by URL.  All are surfaced to the
/// caller (mapped to an MCP `invalidArguments` detail) so the agent learns why
/// the URL was rejected rather than seeing an opaque failure.
enum SupportFileFetchError: Error, Equatable, Sendable {
    case invalidURL(String)
    case schemeNotAllowed(String)
    case credentialsInURL
    case dnsFailed(host: String)
    case blockedAddress(host: String, ip: String)
    case unexpectedStatus(Int)
    case tooLarge(maxBytes: Int)
    case notUTF8

    /// Human-readable detail for an MCP tool error.
    var toolDetail: String {
        switch self {
        case .invalidURL(let url):
            return "sourceUrl is not a valid URL: \"\(url)\"."
        case .schemeNotAllowed(let scheme):
            return "sourceUrl must be an https:// URL (got scheme \"\(scheme)\")."
        case .credentialsInURL:
            return "sourceUrl must not embed credentials (user:pass@…)."
        case .dnsFailed(let host):
            return "sourceUrl host \"\(host)\" could not be resolved."
        case .blockedAddress(let host, let ip):
            return
                "sourceUrl host \"\(host)\" resolves to a non-public address (\(ip)); "
                + "fetching loopback, private, link-local, or cloud-metadata addresses is refused."
        case .unexpectedStatus(let code):
            return "sourceUrl returned HTTP \(code) (expected 200, and redirects are not followed)."
        case .tooLarge(let maxBytes):
            return "sourceUrl body exceeds the \(maxBytes / (1024 * 1024)) MB support-file limit."
        case .notUTF8:
            return "sourceUrl body is not valid UTF-8 text (binary support files are not yet supported)."
        }
    }
}

enum SupportFileURLFetcher {
    /// Hard cap on a fetched support file.  The MCP route's body limit is 10 MB;
    /// a support file lives in the same setup zip, so this stays comfortably
    /// under it.  Compile-time constant — deliberately not an env var.
    static let maxBytes = 8 * 1024 * 1024
    static let connectTimeout: TimeAmount = .seconds(10)
    static let readTimeout: TimeAmount = .seconds(15)
    static let overallTimeout: TimeAmount = .seconds(20)

    /// Validates the URL (https, no userinfo, has a host) and returns the host.
    static func validate(_ urlString: String) throws -> String {
        guard let comps = URLComponents(string: urlString) else {
            throw SupportFileFetchError.invalidURL(urlString)
        }
        guard (comps.scheme ?? "").lowercased() == "https" else {
            throw SupportFileFetchError.schemeNotAllowed(comps.scheme ?? "")
        }
        guard comps.user == nil, comps.password == nil else {
            throw SupportFileFetchError.credentialsInURL
        }
        guard var host = comps.host, !host.isEmpty else {
            throw SupportFileFetchError.invalidURL(urlString)
        }
        // Some Foundation builds keep the [..] around an IPv6 literal host.
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return host
    }

    /// Fetches the URL under the SSRF guards and returns the raw body bytes.
    /// Shared by `fetch` (UTF-8 text) and `fetchData` (binary).
    static func fetchBytes(urlString: String, on request: Request) async throws -> Data {
        let host = try validate(urlString)

        // Resolve + classify before connecting.  An IP literal is classified
        // directly; a hostname is resolved (off the event loop) and every
        // returned address must be public.
        let addresses: [String]
        if BlockedIPClassifier.isIPLiteral(host) {
            addresses = [host]
        } else {
            addresses = try await request.application.threadPool.runIfActive(eventLoop: request.eventLoop) {
                try resolveHostAddresses(host)
            }.get()
        }
        guard !addresses.isEmpty else { throw SupportFileFetchError.dnsFailed(host: host) }
        for ip in addresses where BlockedIPClassifier.isBlocked(ip) {
            // The resolved address is instructor-URL infrastructure, not a
            // client IP, but it still goes in metadata: the admin query_logs
            // buffer redacts the "ip" key while console logging keeps it.
            request.logger.warning(
                "mcp.support_file_fetch.blocked host=\(host)",
                metadata: ["ip": .string("\(ip)")])
            throw SupportFileFetchError.blockedAddress(host: host, ip: ip)
        }

        let configuration = HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: connectTimeout, read: readTimeout))
        let client = HTTPClient(
            eventLoopGroupProvider: .shared(request.application.eventLoopGroup),
            configuration: configuration)

        // Run the request, then shut the dedicated client down exactly once
        // regardless of outcome (a per-call client keeps the no-redirect config
        // off the shared client).
        let outcome: Result<Data, Error>
        do {
            outcome = .success(try await performFetch(client, urlString: urlString))
        } catch {
            outcome = .failure(error)
        }
        try? await client.shutdown()

        let bytes = try outcome.get()
        request.logger.info(
            "mcp.support_file_fetch host=\(host) bytes=\(bytes.count) status=ok")
        return bytes
    }

    /// Fetches the URL under the SSRF guards and returns the body as UTF-8 text.
    static func fetch(urlString: String, on request: Request) async throws -> String {
        let bytes = try await fetchBytes(urlString: urlString, on: request)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw SupportFileFetchError.notUTF8
        }
        return text
    }

    /// Fetches the URL under the SSRF guards and returns the raw bytes — for
    /// binary content files (PDFs, images, notebooks) that need no UTF-8
    /// requirement. Same guards as `fetch`.
    static func fetchData(urlString: String, on request: Request) async throws -> Data {
        try await fetchBytes(urlString: urlString, on: request)
    }

    private static func performFetch(_ client: HTTPClient, urlString: String) async throws -> Data {
        var httpRequest = HTTPClientRequest(url: urlString)
        httpRequest.method = .GET
        let response = try await client.execute(httpRequest, timeout: overallTimeout)
        guard response.status == .ok else {
            throw SupportFileFetchError.unexpectedStatus(Int(response.status.code))
        }
        let buffer: ByteBuffer
        do {
            buffer = try await response.body.collect(upTo: maxBytes)
        } catch {
            // .collect throws NIOTooManyBytesError once the stream passes the
            // cap, so we abort mid-download rather than trusting Content-Length.
            throw SupportFileFetchError.tooLarge(maxBytes: maxBytes)
        }
        return Data(buffer.readableBytesView)
    }

    /// Resolves a hostname to every numeric address it maps to (v4 and v6).
    /// Blocking (getaddrinfo); call on a thread-pool, not the event loop.
    static func resolveHostAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = 0
        hints.ai_protocol = 0

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let head = result else {
            throw SupportFileFetchError.dnsFailed(host: host)
        }
        defer { freeaddrinfo(head) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard let sockaddr = current.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(
                sockaddr, current.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            // `String(cString: [CChar])` is deprecated; the pointer overload is
            // not. getnameinfo writes a NUL-terminated string into `buffer`.
            let ip = buffer.withUnsafeBufferPointer { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base)
            }
            if !ip.isEmpty, !addresses.contains(ip) { addresses.append(ip) }
        }
        return addresses
    }
}

/// Pure (no DNS, no network) classification of a numeric IP literal as a
/// non-public address that an SSRF guard must refuse.  Returns `true` for any
/// loopback / private / link-local / cloud-metadata / CGNAT / ULA / multicast /
/// reserved / unspecified address, and fails closed for an unparseable input.
enum BlockedIPClassifier {
    static func isIPLiteral(_ host: String) -> Bool {
        parseIPv4(host) != nil || parseIPv6(normalizeV6(host)) != nil
    }

    static func isBlocked(_ ip: String) -> Bool {
        // getnameinfo can return a "%scope" suffix on link-local v6.
        let core = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
        if let v4 = parseIPv4(core) { return isBlockedIPv4(v4) }
        if let v6 = parseIPv6(normalizeV6(core)) { return isBlockedIPv6(v6) }
        // The caller only passes resolved numeric addresses; an unparseable one
        // is unexpected, so refuse it.
        return true
    }

    // MARK: - Range logic

    static func isBlockedIPv4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        let b0 = b[0], b1 = b[1], b2 = b[2]
        if b0 == 0 { return true }  // 0.0.0.0/8 "this host"
        if b0 == 10 { return true }  // 10/8 private
        if b0 == 127 { return true }  // 127/8 loopback
        if b0 == 169 && b1 == 254 { return true }  // 169.254/16 link-local + metadata
        if b0 == 172 && (16...31).contains(b1) { return true }  // 172.16/12 private
        if b0 == 192 && b1 == 168 { return true }  // 192.168/16 private
        if b0 == 100 && (64...127).contains(b1) { return true }  // 100.64/10 CGNAT
        if b0 == 198 && (18...19).contains(b1) { return true }  // 198.18/15 benchmark
        if b0 == 192 && b1 == 0 && b2 == 0 { return true }  // 192.0.0/24 IETF
        if b0 == 192 && b1 == 0 && b2 == 2 { return true }  // 192.0.2/24 TEST-NET-1
        if b0 == 198 && b1 == 51 && b2 == 100 { return true }  // 198.51.100/24 TEST-NET-2
        if b0 == 203 && b1 == 0 && b2 == 113 { return true }  // 203.0.113/24 TEST-NET-3
        if b0 >= 224 { return true }  // 224/4 multicast + 240/4 reserved + broadcast
        return false
    }

    static func isBlockedIPv6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        // IPv4-mapped ::ffff:a.b.c.d — classify the embedded v4.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isBlockedIPv4(Array(b[12..<16]))
        }
        // NAT64 well-known prefix 64:ff9b::/96 — embeds a v4.
        if Array(b[0..<12]) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
            return isBlockedIPv4(Array(b[12..<16]))
        }
        // High 96 bits zero: ::, ::1, and IPv4-compatible ::a.b.c.d.
        if b[0..<12].allSatisfy({ $0 == 0 }) {
            let v4 = Array(b[12..<16])
            return v4.allSatisfy { $0 == 0 } ? true : isBlockedIPv4(v4)
        }
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }  // fc00::/7 unique-local
        if b[0] == 0xff { return true }  // ff00::/8 multicast
        return false
    }

    // MARK: - Parsing

    /// Strips a "%scope" suffix and surrounding brackets so an inet_pton parse
    /// of an IPv6 literal succeeds.
    private static func normalizeV6(_ host: String) -> String {
        var s = host
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        return s
    }

    static func parseIPv4(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        let ok = s.withCString { inet_pton(AF_INET, $0, &addr) }
        guard ok == 1 else { return nil }
        var net = addr.s_addr  // network byte order: bytes are the octets in order
        return withUnsafeBytes(of: &net) { Array($0) }
    }

    static func parseIPv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard ok == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0) }
        return bytes.count == 16 ? bytes : nil
    }
}
