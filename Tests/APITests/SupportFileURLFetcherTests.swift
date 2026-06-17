// APITests/SupportFileURLFetcherTests.swift
//
// The SSRF guard for author_script(sourceUrl:) is only as good as its IP-range
// classification, so the pure `BlockedIPClassifier` is exercised exhaustively
// here (no DNS, no network), alongside the URL validation. The actual fetch
// (DNS + HTTP) is integration-territory and not covered by these unit tests.

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
