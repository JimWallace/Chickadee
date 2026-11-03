// APITests/Assignments/SupportFileURLPinningTests.swift
//
// The support-file fetcher must connect to an address that passed the SSRF
// check (#2780). It resolves the host once and pins the client to a checked
// address with `dnsOverride`, so a second lookup cannot return a private
// address. These tests inject a resolver: no DNS, no network.

import AsyncHTTPClient
import Foundation
import Logging
import Synchronization
import Testing

@testable import APIServer

@Suite struct SupportFileURLPinningTests {

    /// A resolver that answers `first` on the first call and `later` on every
    /// call after it, the way a zero-TTL rebinding record does.
    final class RebindingResolver: Sendable {
        let first: [String]
        let later: [String]
        let calls = Mutex(0)

        init(first: [String], later: [String]) {
            self.first = first
            self.later = later
        }

        var callCount: Int { calls.withLock { $0 } }

        func resolve(_ host: String) -> [String] {
            let call = calls.withLock { count in
                count += 1
                return count
            }
            return call == 1 ? first : later
        }
    }

    let logger = Logger(label: "SupportFileURLPinningTests")

    @Test("a resolver whose second answer is private is asked once, and the client is pinned to the first answer")
    func resolverIsAskedOnceAndPinned() async throws {
        let resolver = RebindingResolver(first: ["93.184.216.34"], later: ["10.0.0.5"])
        let url = "https://files.example.org/data.csv"
        let host = try SupportFileURLFetcher.validate(url)

        let override = try await SupportFileURLFetcher.pinnedDNSOverride(
            urlString: url, host: host, logger: logger
        ) { name in resolver.resolve(name) }
        let configuration = SupportFileURLFetcher.clientConfiguration(dnsOverride: override)

        #expect(resolver.callCount == 1)
        #expect(configuration.dnsOverride == ["files.example.org": "93.184.216.34"])
        #expect(configuration.dnsOverride.values.allSatisfy { !BlockedIPClassifier.isBlocked($0) })
    }

    @Test("a public answer that also holds a private address is refused")
    func mixedAnswerIsRefused() async {
        let resolver = RebindingResolver(first: ["93.184.216.34", "169.254.169.254"], later: [])
        let url = "https://files.example.org/data.csv"

        await #expect(throws: SupportFileFetchError.blockedAddress(host: "files.example.org", ip: "169.254.169.254")) {
            _ = try await SupportFileURLFetcher.pinnedDNSOverride(
                urlString: url, host: "files.example.org", logger: logger
            ) { name in resolver.resolve(name) }
        }
        #expect(resolver.callCount == 1)
    }

    @Test("an empty answer is a DNS failure")
    func emptyAnswerFails() async {
        let url = "https://files.example.org/data.csv"
        await #expect(throws: SupportFileFetchError.dnsFailed(host: "files.example.org")) {
            _ = try await SupportFileURLFetcher.pinnedDNSOverride(
                urlString: url, host: "files.example.org", logger: logger
            ) { _ in [] }
        }
    }

    @Test("an IPv4 address is pinned before an IPv6 address")
    func ipv4IsPreferred() async throws {
        let url = "https://files.example.org/data.csv"
        let override = try await SupportFileURLFetcher.pinnedDNSOverride(
            urlString: url, host: "files.example.org", logger: logger
        ) { _ in ["2606:2800:220:1:248:1893:25c8:1946", "93.184.216.34"] }
        #expect(override == ["files.example.org": "93.184.216.34"])
    }

    @Test("an IPv6-only answer pins the IPv6 address")
    func ipv6OnlyIsPinned() async throws {
        let url = "https://files.example.org/data.csv"
        let override = try await SupportFileURLFetcher.pinnedDNSOverride(
            urlString: url, host: "files.example.org", logger: logger
        ) { _ in ["2606:2800:220:1:248:1893:25c8:1946"] }
        #expect(override == ["files.example.org": "2606:2800:220:1:248:1893:25c8:1946"])
    }

    @Test("an IP-literal host is checked without a lookup and needs no pin")
    func ipLiteralNeedsNoPin() async throws {
        let resolver = RebindingResolver(first: ["10.0.0.5"], later: ["10.0.0.5"])
        let override = try await SupportFileURLFetcher.pinnedDNSOverride(
            urlString: "https://93.184.216.34/data.csv", host: "93.184.216.34", logger: logger
        ) { name in resolver.resolve(name) }
        #expect(override.isEmpty)
        #expect(resolver.callCount == 0)
    }

    @Test("a private IP-literal host is refused")
    func privateIPLiteralIsRefused() async {
        await #expect(throws: SupportFileFetchError.blockedAddress(host: "127.0.0.1", ip: "127.0.0.1")) {
            _ = try await SupportFileURLFetcher.pinnedDNSOverride(
                urlString: "https://127.0.0.1/data.csv", host: "127.0.0.1", logger: logger
            ) { _ in [] }
        }
    }
}
