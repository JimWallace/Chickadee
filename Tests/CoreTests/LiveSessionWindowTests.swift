// Tests/CoreTests/LiveSessionWindowTests.swift
//
// `LiveSessionWindow` and the way `ClassActivity` stores one. The API-level
// behaviour is covered in APITests/ActivitySessionWindowTests.swift, but the
// weekly mutation sweep skips APITests, so every operator in this type
// survived it. These tests exercise the type directly, where the sweep can
// see them.

import Core
import Foundation
import Testing

@Suite struct LiveSessionWindowTests {

    private let opens = "2026-01-01T10:00:00Z"
    private let closes = "2026-01-01T11:00:00Z"

    private var openInstant: Date { Date(timeIntervalSince1970: 1_767_261_600) }
    private var closeInstant: Date { openInstant.addingTimeInterval(3600) }

    // MARK: Construction

    @Test func emptyStringBoundsAreStoredAsAbsent() {
        let window = LiveSessionWindow(opensAtISO: "", closesAtISO: "")
        #expect(window.opensAtISO == nil)
        #expect(window.closesAtISO == nil)
    }

    @Test func nonEmptyBoundsAreKeptVerbatim() {
        let window = LiveSessionWindow(opensAtISO: opens, closesAtISO: closes)
        #expect(window.opensAtISO == opens)
        #expect(window.closesAtISO == closes)
    }

    @Test func eachBoundIsNormalisedIndependently() {
        let onlyCloses = LiveSessionWindow(opensAtISO: "", closesAtISO: closes)
        #expect(onlyCloses.opensAtISO == nil)
        #expect(onlyCloses.closesAtISO == closes)

        let onlyOpens = LiveSessionWindow(opensAtISO: opens, closesAtISO: "")
        #expect(onlyOpens.opensAtISO == opens)
        #expect(onlyOpens.closesAtISO == nil)
    }

    // MARK: Parsing and formatting

    @Test func formatWritesWholeSecondsWithoutAFraction() {
        #expect(LiveSessionWindow.format(openInstant) == opens)
        let fractional = openInstant.addingTimeInterval(0.5)
        #expect(LiveSessionWindow.format(fractional) == opens)
    }

    @Test func parseAcceptsWholeAndFractionalSecondsAndRejectsOtherText() {
        #expect(LiveSessionWindow.parse(opens) == openInstant)
        let fractional = LiveSessionWindow.parse("2026-01-01T10:00:00.500Z")
        #expect(fractional == openInstant.addingTimeInterval(0.5))
        #expect(LiveSessionWindow.parse("not a date") == nil)
        #expect(LiveSessionWindow.parse("") == nil)
        #expect(LiveSessionWindow.parse(nil) == nil)
    }

    // MARK: Bound predicates

    @Test func isBoundedIsTrueWhenEitherBoundIsPresent() {
        #expect(!LiveSessionWindow().isBounded)
        #expect(LiveSessionWindow(opensAtISO: opens).isBounded)
        #expect(LiveSessionWindow(closesAtISO: closes).isBounded)
        #expect(LiveSessionWindow(opensAtISO: opens, closesAtISO: closes).isBounded)
    }

    @Test func aBoundThatDoesNotParseIsStillAnAuthoredBound() {
        #expect(LiveSessionWindow(opensAtISO: "soon").isBounded)
        #expect(LiveSessionWindow(closesAtISO: "later").isBounded)
    }

    @Test func boundsAreReadableOnlyWhenEveryPresentBoundParses() {
        #expect(LiveSessionWindow().boundsAreReadable)
        #expect(LiveSessionWindow(opensAtISO: opens).boundsAreReadable)
        #expect(LiveSessionWindow(closesAtISO: closes).boundsAreReadable)
        #expect(LiveSessionWindow(opensAtISO: opens, closesAtISO: closes).boundsAreReadable)

        #expect(!LiveSessionWindow(opensAtISO: "soon").boundsAreReadable)
        #expect(!LiveSessionWindow(closesAtISO: "later").boundsAreReadable)
        #expect(!LiveSessionWindow(opensAtISO: "soon", closesAtISO: closes).boundsAreReadable)
        #expect(!LiveSessionWindow(opensAtISO: opens, closesAtISO: "later").boundsAreReadable)
        #expect(!LiveSessionWindow(opensAtISO: "soon", closesAtISO: "later").boundsAreReadable)
    }

    @Test func boundsAreOrderedOnlyWhenTheWindowCloseIsAfterTheOpen() {
        #expect(LiveSessionWindow(opensAtISO: opens, closesAtISO: closes).boundsAreOrdered)
        #expect(!LiveSessionWindow(opensAtISO: closes, closesAtISO: opens).boundsAreOrdered)
        #expect(!LiveSessionWindow(opensAtISO: opens, closesAtISO: opens).boundsAreOrdered)
        #expect(LiveSessionWindow(opensAtISO: opens).boundsAreOrdered)
        #expect(LiveSessionWindow(closesAtISO: closes).boundsAreOrdered)
    }

    // MARK: State

    @Test func stateIsHalfOpenAtBothBounds() {
        let window = LiveSessionWindow(opensAt: openInstant, closesAt: closeInstant)
        #expect(window.state(at: openInstant.addingTimeInterval(-1)) == .beforeOpen)
        #expect(window.state(at: openInstant) == .open)
        #expect(window.state(at: openInstant.addingTimeInterval(1)) == .open)
        #expect(window.state(at: closeInstant.addingTimeInterval(-1)) == .open)
        #expect(window.state(at: closeInstant) == .afterClose)
        #expect(window.state(at: closeInstant.addingTimeInterval(1)) == .afterClose)
    }

    @Test func anOpenEndedWindowNeverCloses() {
        let window = LiveSessionWindow(opensAt: openInstant, closesAt: nil)
        #expect(window.state(at: openInstant.addingTimeInterval(-1)) == .beforeOpen)
        #expect(window.state(at: openInstant.addingTimeInterval(1_000_000)) == .open)
    }

    @Test func aWindowWithNoStartIsOpenUntilItCloses() {
        let window = LiveSessionWindow(opensAt: nil, closesAt: closeInstant)
        #expect(window.state(at: closeInstant.addingTimeInterval(-1_000_000)) == .open)
        #expect(window.state(at: closeInstant) == .afterClose)
    }

    @Test func acceptsIsTrueExactlyWhileTheWindowIsOpen() {
        let window = LiveSessionWindow(opensAt: openInstant, closesAt: closeInstant)
        #expect(!window.accepts(at: openInstant.addingTimeInterval(-1)))
        #expect(window.accepts(at: openInstant.addingTimeInterval(1)))
        #expect(!window.accepts(at: closeInstant))
    }

    @Test func nextBoundaryIsWhatTheCountdownCountsDownTo() {
        let window = LiveSessionWindow(opensAt: openInstant, closesAt: closeInstant)
        #expect(window.nextBoundary(at: openInstant.addingTimeInterval(-1)) == openInstant)
        #expect(window.nextBoundary(at: openInstant.addingTimeInterval(1)) == closeInstant)
        #expect(window.nextBoundary(at: closeInstant) == nil)
    }
}

@Suite struct ClassActivityWindowStorageTests {

    private let opens = "2026-01-01T10:00:00Z"
    private let closes = "2026-01-01T11:00:00Z"

    @Test func anUnboundedWindowIsStoredAsNoWindow() {
        let activity = ClassActivity(kind: .bestMetric, window: LiveSessionWindow())
        #expect(activity.window == nil)
    }

    @Test func aBoundedWindowIsKept() {
        let window = LiveSessionWindow(opensAtISO: opens, closesAtISO: closes)
        let activity = ClassActivity(kind: .bestMetric, window: window)
        #expect(activity.window == window)
    }

    @Test func decodingDropsAnUnboundedWindowAndKeepsABoundedOne() throws {
        let unbounded = Data(#"{"kind":"bestMetric","window":{}}"#.utf8)
        #expect(try JSONDecoder().decode(ClassActivity.self, from: unbounded).window == nil)

        let bounded = Data(
            #"{"kind":"bestMetric","window":{"opensAtISO":"\#(opens)"}}"#.utf8)
        let decoded = try JSONDecoder().decode(ClassActivity.self, from: bounded)
        #expect(decoded.window == LiveSessionWindow(opensAtISO: opens))
    }

    @Test func aWindowlessActivityAcceptsAtAnyTime() {
        let activity = ClassActivity(kind: .bestMetric)
        #expect(activity.acceptsSubmissions(at: Date(timeIntervalSince1970: 0)))
    }

    @Test func aWindowedActivityAcceptsOnlyInsideItsWindow() {
        let window = LiveSessionWindow(opensAtISO: opens, closesAtISO: closes)
        let activity = ClassActivity(kind: .bestMetric, window: window)
        let inside = Date(timeIntervalSince1970: 1_767_261_600 + 60)
        let after = Date(timeIntervalSince1970: 1_767_261_600 + 7200)
        #expect(activity.acceptsSubmissions(at: inside))
        #expect(!activity.acceptsSubmissions(at: after))
    }
}
