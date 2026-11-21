// Tests/APITests/Assignments/SupportFileURLFetcherTests.swift
//
// The SSRF guard for author_script(sourceUrl:) is only as good as its IP-range
// classification, so the pure `BlockedIPClassifier` is exercised exhaustively
// here (no DNS, no network), alongside the URL validation.
//
// `SupportFileURLFetcherRefusalTests` covers the refusals that the classifier
// tests do not reach: the error prose an agent reads, a URL that does not
// parse, a host that `URL(string:)` reads differently from the checked host,
// the real resolver (`getaddrinfo`), and `fetch` / `fetchData` refusing a
// non-public host before any connection is made. No test here opens a
// connection. The resolver tests ask only for `localhost` and numeric hosts,
// which resolve from the local host table.

import Foundation
import Logging
import Synchronization
import Testing

@testable import APIServer

@Suite struct SupportFileURLFetcherTests {

    // MARK: - Blocked addresses (must never be fetched)

    @Test(
        "non-public IPv4 is blocked",
        arguments: [
            "0.0.0.0",  // this-host
            "0.1.2.3",
            "10.0.0.1", "10.255.255.255",  // private
            "127.0.0.1", "127.1.2.3",  // loopback
            "169.254.169.254",  // cloud metadata (the classic SSRF target)
            "169.254.0.1",  // link-local
            "172.16.0.1", "172.20.5.5", "172.31.255.255",  // private
            "192.168.0.1", "192.168.255.255",  // private
            "100.64.0.1", "100.127.255.255",  // CGNAT
            "198.18.0.1", "198.19.255.255",  // benchmark
            "192.0.0.1",  // IETF protocol assignments
            "192.0.2.5",  // TEST-NET-1
            "198.51.100.5",  // TEST-NET-2
            "203.0.113.5",  // TEST-NET-3
            "224.0.0.1", "239.255.255.255",  // multicast
            "240.0.0.1", "255.255.255.255",  // reserved + broadcast
        ])
    func blockedIPv4(_ ip: String) {
        #expect(BlockedIPClassifier.isBlocked(ip), "\(ip) should be blocked")
    }

    @Test(
        "non-public IPv6 is blocked",
        arguments: [
            "::",  // unspecified
            "::1",  // loopback
            "fe80::1",  // link-local
            "fe80::abcd:1234",
            "fc00::1",  // unique-local
            "fd12:3456:789a::1",  // unique-local
            "ff02::1",  // multicast
            "ff00::1",
            "::ffff:127.0.0.1",  // IPv4-mapped loopback
            "::ffff:10.0.0.1",  // IPv4-mapped private
            "::ffff:169.254.169.254",  // IPv4-mapped metadata
            "64:ff9b::7f00:1",  // NAT64-wrapped 127.0.0.1
        ])
    func blockedIPv6(_ ip: String) {
        #expect(BlockedIPClassifier.isBlocked(ip), "\(ip) should be blocked")
    }

    @Test("link-local IPv6 with a zone suffix is blocked")
    func blockedIPv6WithZone() {
        #expect(BlockedIPClassifier.isBlocked("fe80::1%eth0"))
    }

    // MARK: - Public addresses (allowed)

    @Test(
        "public IPv4 is allowed",
        arguments: [
            "8.8.8.8", "1.1.1.1",
            "185.199.108.133",  // GitHub Pages / raw.githubusercontent.com range
            "140.82.112.3",  // GitHub
            "11.0.0.1",  // just outside 10/8
            "126.255.255.255", "128.0.0.1",  // either side of 127/8
            "172.15.255.255", "172.32.0.1",  // either side of 172.16/12
            "192.167.255.255", "192.169.0.1",  // either side of 192.168/16
            "100.63.255.255", "100.128.0.1",  // either side of 100.64/10
            "223.255.255.255",  // just below multicast
        ])
    func allowedIPv4(_ ip: String) {
        #expect(!BlockedIPClassifier.isBlocked(ip), "\(ip) should be allowed")
    }

    @Test(
        "public IPv6 is allowed",
        arguments: [
            "2606:4700:4700::1111",  // Cloudflare
            "2001:4860:4860::8888",  // Google
            "2620:0:2d0:200::7",
            "::ffff:8.8.8.8",  // IPv4-mapped public
        ])
    func allowedIPv6(_ ip: String) {
        #expect(!BlockedIPClassifier.isBlocked(ip), "\(ip) should be allowed")
    }

    // MARK: - Parsing fails closed

    @Test("an unparseable address is treated as blocked (fail closed)")
    func unparseableFailsClosed() {
        #expect(BlockedIPClassifier.isBlocked("not-an-ip"))
        #expect(BlockedIPClassifier.isBlocked(""))
        #expect(BlockedIPClassifier.isBlocked("999.999.999.999"))
    }

    @Test("IP-literal detection")
    func ipLiteralDetection() {
        #expect(BlockedIPClassifier.isIPLiteral("8.8.8.8"))
        #expect(BlockedIPClassifier.isIPLiteral("::1"))
        #expect(BlockedIPClassifier.isIPLiteral("2606:4700::1111"))
        #expect(!BlockedIPClassifier.isIPLiteral("example.com"))
        #expect(!BlockedIPClassifier.isIPLiteral("raw.githubusercontent.com"))
    }

    // MARK: - URL validation

    @Test("validate accepts a plain https URL and returns the host")
    func validateAcceptsHTTPS() throws {
        let host = try SupportFileURLFetcher.validate("https://raw.githubusercontent.com/o/r/main/data.csv")
        #expect(host == "raw.githubusercontent.com")
    }

    @Test("validate strips brackets from an IPv6 literal host")
    func validateStripsBrackets() throws {
        let host = try SupportFileURLFetcher.validate("https://[2606:4700::1111]/data.csv")
        #expect(host == "2606:4700::1111")
    }

    @Test(
        "validate rejects non-https schemes",
        arguments: [
            "http://example.com/data.csv",
            "file:///etc/passwd",
            "ftp://example.com/data.csv",
            "gopher://example.com/",
        ])
    func validateRejectsScheme(_ url: String) {
        #expect(throws: SupportFileFetchError.self) {
            try SupportFileURLFetcher.validate(url)
        }
    }

    @Test("validate rejects embedded credentials")
    func validateRejectsUserinfo() {
        #expect(throws: SupportFileFetchError.self) {
            try SupportFileURLFetcher.validate("https://user:pass@example.com/data.csv")
        }
    }

    @Test("validate rejects a URL with no host")
    func validateRejectsNoHost() {
        #expect(throws: SupportFileFetchError.self) {
            try SupportFileURLFetcher.validate("https:///data.csv")
        }
    }
}

// MARK: - Refusals

@Suite(.timeLimit(.minutes(1)))
struct SupportFileURLFetcherRefusalTests {

    let logger = Logger(label: "SupportFileURLFetcherRefusalTests")

    // MARK: - Error prose

    @Test(
        "each fetch error names its cause in the tool detail",
        arguments: [
            (SupportFileFetchError.invalidURL("ht tp://x"), "is not a valid URL: \"ht tp://x\""),
            (.schemeNotAllowed("ftp"), "must be an https:// URL (got scheme \"ftp\")"),
            (.credentialsInURL, "must not embed credentials"),
            (.dnsFailed(host: "files.example.org"), "host \"files.example.org\" could not be resolved"),
            (
                .blockedAddress(host: "files.example.org", ip: "169.254.169.254"),
                "host \"files.example.org\" resolves to a non-public address (169.254.169.254)"
            ),
            (.unexpectedStatus(302), "returned HTTP 302 (expected 200, and redirects are not followed)"),
            (.tooLarge(maxBytes: SupportFileURLFetcher.maxBytes), "exceeds the 8 MB support-file limit"),
            (.notUTF8, "is not valid UTF-8 text"),
        ])
    func toolDetailNamesTheCause(_ error: SupportFileFetchError, _ fragment: String) {
        #expect(error.toolDetail.hasPrefix("sourceUrl "))
        #expect(error.toolDetail.contains(fragment), "\(error.toolDetail)")
    }

    @Test("the blocked-address detail says which kinds of address are refused")
    func blockedDetailListsTheRefusedKinds() {
        let detail = SupportFileFetchError.blockedAddress(host: "h", ip: "10.0.0.1").toolDetail
        #expect(detail.contains("loopback, private, link-local, or cloud-metadata addresses is refused"))
    }

    @Test("the size detail is in megabytes and follows maxBytes")
    func tooLargeDetailFollowsTheCap() {
        #expect(SupportFileFetchError.tooLarge(maxBytes: 3 * 1024 * 1024).toolDetail.contains("the 3 MB"))
        #expect(
            SupportFileFetchError.tooLarge(maxBytes: SupportFileURLFetcher.maxBytes).toolDetail
                .contains("the \(SupportFileURLFetcher.maxBytesText) support-file limit"))
    }

    // MARK: - URL validation, exact errors

    @Test(
        "a string that does not parse as a URL is refused as invalid",
        arguments: ["https://exa mple.com/data.csv", "https://%zz/data.csv", "https://[::1/data.csv"])
    func unparseableURLIsInvalid(_ url: String) {
        #expect(throws: SupportFileFetchError.invalidURL(url)) {
            try SupportFileURLFetcher.validate(url)
        }
    }

    @Test("the refused scheme is reported, and a URL with no scheme reports an empty one")
    func refusedSchemeIsReported() {
        #expect(throws: SupportFileFetchError.schemeNotAllowed("http")) {
            try SupportFileURLFetcher.validate("http://files.example.org/data.csv")
        }
        #expect(throws: SupportFileFetchError.schemeNotAllowed("")) {
            try SupportFileURLFetcher.validate("//files.example.org/data.csv")
        }
    }

    @Test("an upper-case HTTPS scheme is accepted")
    func upperCaseSchemeIsAccepted() throws {
        #expect(try SupportFileURLFetcher.validate("HTTPS://files.example.org/data.csv") == "files.example.org")
    }

    @Test("a user name without a password is refused as embedded credentials")
    func userWithoutPasswordIsRefused() {
        #expect(throws: SupportFileFetchError.credentialsInURL) {
            try SupportFileURLFetcher.validate("https://agent@files.example.org/data.csv")
        }
    }

    // MARK: - The pinned host must be the host the client connects to

    @Test("a host that URL(string:) reads differently from the checked host is refused without a lookup")
    func hostMismatchIsRefused() async throws {
        let url = "https://xn--e1afmkfd.com/data.csv"
        let host = try SupportFileURLFetcher.validate(url)
        try #require(URL(string: url)?.host != host, "the two parsers must disagree on this host")

        let calls = Mutex(0)
        await #expect(throws: SupportFileFetchError.invalidURL(url)) {
            _ = try await SupportFileURLFetcher.pinnedDNSOverride(
                urlString: url, host: host, logger: logger
            ) { _ in
                calls.withLock { $0 += 1 }
                return ["93.184.216.34"]
            }
        }
        #expect(calls.withLock { $0 } == 0)
    }

    // MARK: - The real resolver

    @Test("localhost resolves only to blocked loopback addresses")
    func localhostResolvesToLoopback() throws {
        let addresses = try SupportFileURLFetcher.resolveHostAddresses("localhost")
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { BlockedIPClassifier.isBlocked($0) })
        #expect(addresses.contains { $0 == "127.0.0.1" || $0 == "::1" })
    }

    @Test("each address is returned once, though getaddrinfo lists one entry per socket type")
    func resolvedAddressesAreUnique() throws {
        let addresses = try SupportFileURLFetcher.resolveHostAddresses("127.0.0.1")
        #expect(addresses == ["127.0.0.1"])
    }

    @Test(
        "an obfuscated IPv4 host resolves to its canonical loopback address",
        arguments: ["2130706433", "0x7f.0.0.1", "127.1"])
    func obfuscatedLiteralIsCanonicalised(_ host: String) throws {
        #expect(!BlockedIPClassifier.isIPLiteral(host))
        let addresses = try SupportFileURLFetcher.resolveHostAddresses(host)
        #expect(addresses == ["127.0.0.1"])
    }

    @Test("a name that does not resolve is a DNS failure")
    func emptyNameIsADNSFailure() {
        #expect(throws: SupportFileFetchError.dnsFailed(host: "")) {
            try SupportFileURLFetcher.resolveHostAddresses("")
        }
    }

    // MARK: - fetch and fetchData refuse before they connect

    @Test("fetch refuses a URL whose host resolves to loopback")
    func fetchRefusesLocalhost() async throws {
        let app = try await makeTestingApplication { _ in }
        try await withApp(app) { app in
            let error = await #expect(throws: SupportFileFetchError.self) {
                _ = try await SupportFileURLFetcher.fetch(
                    urlString: "https://localhost/data.csv", on: makeTestRequest(on: app))
            }
            let loopbackRefusals = ["127.0.0.1", "::1"].map {
                SupportFileFetchError.blockedAddress(host: "localhost", ip: $0)
            }
            let refusal = try #require(error)
            #expect(loopbackRefusals.contains(refusal), "\(refusal)")
        }
    }

    @Test("fetchData refuses an obfuscated loopback host")
    func fetchDataRefusesObfuscatedLoopback() async throws {
        let app = try await makeTestingApplication { _ in }
        try await withApp(app) { app in
            await #expect(throws: SupportFileFetchError.blockedAddress(host: "2130706433", ip: "127.0.0.1")) {
                _ = try await SupportFileURLFetcher.fetchData(
                    urlString: "https://2130706433/data.csv", on: makeTestRequest(on: app))
            }
        }
    }

    @Test("fetch and fetchData refuse a cloud-metadata literal and a non-https URL")
    func fetchRefusesMetadataAndScheme() async throws {
        let app = try await makeTestingApplication { _ in }
        try await withApp(app) { app in
            let request = makeTestRequest(on: app)
            await #expect(
                throws: SupportFileFetchError.blockedAddress(host: "169.254.169.254", ip: "169.254.169.254")
            ) {
                _ = try await SupportFileURLFetcher.fetchData(
                    urlString: "https://169.254.169.254/latest/meta-data/", on: request)
            }
            await #expect(throws: SupportFileFetchError.schemeNotAllowed("http")) {
                _ = try await SupportFileURLFetcher.fetch(urlString: "http://files.example.org/data.csv", on: request)
            }
        }
    }
}
