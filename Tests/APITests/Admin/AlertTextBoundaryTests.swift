import Foundation
import Testing

@testable import APIServer

/// The edges of the alert-summary wording in `AlertText.swift`.
///
/// `AlertNamedListTests` checks a short list and a long list. This suite
/// checks the list that is exactly at the limit, and the durations that sit
/// exactly on an hour or a day. A summary must not say "and 0 more", and must
/// not say "0h" or "0d".
@Suite struct AlertTextBoundaryTests {

    @Test func aListAtTheLimitNamesEveryEntryAndNoMore() {
        let names = (1...alertNamedListLimit).map { "R\($0)" }
        #expect(alertNamedList(names) == names.joined(separator: ", "))
    }

    @Test func aListOneOverTheLimitSaysOneMore() {
        let names = (1...(alertNamedListLimit + 1)).map { "R\($0)" }
        let shown = names.prefix(alertNamedListLimit).joined(separator: ", ")
        #expect(alertNamedList(names) == shown + ", and 1 more")
    }

    @Test func aCustomLimitIsObeyed() {
        #expect(alertNamedList(["A", "B", "C"], limit: 2) == "A, B, and 1 more")
        #expect(alertNamedList(["A", "B"], limit: 2) == "A, B")
        #expect(alertNamedList([]).isEmpty)
    }

    @Test(arguments: [
        (0.0, "0m"),
        (59.0, "0m"),
        (3_599.0, "59m"),
        (3_600.0, "1h 0m"),
        (86_399.0, "23h 59m"),
        (86_400.0, "1d 0h"),
        (90_000.0, "1d 1h"),
    ])
    func aDurationOnAnHourOrADayBoundaryUsesTheLargerUnit(seconds: Double, expected: String) {
        #expect(formatQuietDuration(seconds) == expected)
    }
}
