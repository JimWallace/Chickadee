// Tests/APITests/LTI/LTIToolEndpointsTests.swift
//
// The tool URLs the admin page shows an LMS administrator. A doubled slash or
// a relative URL here would break the registration at the LMS, far from here.

import Foundation
import Testing

@testable import APIServer

@Suite struct LTIToolEndpointsTests {
    @Test(arguments: ["https://chickadee.example.edu", "https://chickadee.example.edu/", "https://chickadee.example.edu//"])
    func absoluteURLsHaveOneSlashBeforeThePath(base: String) throws {
        let endpoints = LTIToolEndpoints(publicBaseURL: try #require(URL(string: base)))
        #expect(endpoints.isAbsolute)
        #expect(endpoints.loginURL == "https://chickadee.example.edu/lti/login")
        #expect(endpoints.launchURL == "https://chickadee.example.edu/lti/launch")
        #expect(endpoints.jwksURL == "https://chickadee.example.edu/lti/jwks")
    }

    @Test func withoutABaseURLTheEndpointsArePathsAndSaySo() {
        let endpoints = LTIToolEndpoints(publicBaseURL: nil)
        #expect(!endpoints.isAbsolute)
        #expect(endpoints.jwksURL == "/lti/jwks")
    }
}
