// APITests/Assignments/SupportFileURLFetcherRefusalTests.swift
//
// The refusals of the support-file fetcher that the classifier and pinning
// suites do not reach: the error prose an agent reads, a URL that does not
// parse, a host that `URL(string:)` reads differently from the checked host,
// the real resolver (`getaddrinfo`), and `fetch` / `fetchData` refusing a
// non-public host before any connection is made.
//
// No test here opens a connection. The resolver tests ask only for
// `localhost` and numeric hosts, which resolve from the local host table.

import Foundation
import Logging
import Synchronization
import Testing

@testable import APIServer

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
