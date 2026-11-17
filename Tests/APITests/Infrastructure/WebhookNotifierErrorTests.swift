// Tests/APITests/Infrastructure/WebhookNotifierErrorTests.swift
//
// `WebhookNotifierError.description` is what the health-alert monitor logs
// when an alert webhook fails. A test cannot reach that failure without a
// live endpoint, so these pin the two messages directly.

import Testing

@testable import APIServer

@Suite struct WebhookNotifierErrorTests {

    @Test func invalidURLNamesTheURL() {
        let error = WebhookNotifierError.invalidURL("not a url")
        #expect(error.description == "Invalid webhook URL: not a url")
    }

    @Test func unexpectedStatusNamesTheStatus() {
        let error = WebhookNotifierError.unexpectedStatus(503)
        #expect(error.description == "Webhook responded with HTTP 503")
    }
}
