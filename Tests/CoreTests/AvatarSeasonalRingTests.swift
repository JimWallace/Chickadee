// Tests/CoreTests/AvatarSeasonalRingTests.swift
//
// The seasonal rings (docs/student-wardrobe.md, "Seasonal rings"): one per
// Waterloo term, open to choose only during that term, and kept after it.

import Core
import Foundation
import Testing

@Suite struct AvatarSeasonalRingTests {

    private static let base = AvatarSpec(
        cap: .umber, wing: .plain, expression: .bright, accessory: .none, accent: .moss,
        backdrop: .sage, tuft: .none, tilt: .upright, border: .none)

    // MARK: - The Waterloo term of a date

    @Test(arguments: [
        (1, TermSeason.winter), (4, .winter), (5, .spring), (8, .spring), (9, .fall), (12, .fall),
    ])
    func eachMonthFallsInOneTerm(month: Int, season: TermSeason) {
        #expect(TermSeason.containing(month: month) == season)
    }

    /// 02:00 UTC on 1 September is still 31 August in Waterloo, so the term
    /// is Spring, not Fall.
    @Test func theTermIsReadOnTheWaterlooCalendar() throws {
        let lateAugust = try #require(ISO8601DateFormatter().date(from: "2026-09-01T02:00:00Z"))
        #expect(TermSeason.current(at: lateAugust) == .spring)
        let earlySeptember = try #require(ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z"))
        #expect(TermSeason.current(at: earlySeptember) == .fall)
    }

    // MARK: - One ring per term

    @Test func everyTermHasExactlyOneSeasonalRing() {
        for season in TermSeason.allCases {
            let rings = AvatarBorder.allCases.filter { $0.season == season }
            #expect(rings.count == 1, "\(season) has \(rings)")
        }
    }

    @Test func aRingIsSeasonalExactlyWhenItHasATerm() {
        for border in AvatarBorder.allCases {
            #expect((border.availability == .seasonal) == (border.season != nil), "\(border)")
        }
    }

    @Test func eachSeasonalRingDrawsItsOwnArt() {
        #expect(AvatarBorder.snowflake.ring == .snowflake)
        #expect(AvatarBorder.blossom.ring == .blossom)
        #expect(AvatarBorder.maple.ring == .maple)
    }

    // MARK: - Open during its term only

    @Test(arguments: TermSeason.allCases)
    func aSeasonalRingIsOpenOnlyDuringItsTerm(season: TermSeason) {
        for border in AvatarBorder.allCases where border.availability == .seasonal {
            #expect(
                AvatarCustomization.isOpen(border.rawValue, for: .border, season: season)
                    == (border.season == season), "\(border) in \(season)")
        }
    }

    @Test func aStudentCanChooseTheRingOfTheTerm() throws {
        let updated = try AvatarCustomization.applying(
            ["border": "maple"], to: Self.base, isStaff: false, season: .fall)
        #expect(updated.border == .maple)
    }

    @Test func aRingOutOfItsTermIsRefusedAndChangesNothing() {
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .border, value: "maple")) {
            try AvatarCustomization.applying(
                ["backdrop": "rose", "border": "maple"], to: Self.base, isStaff: false,
                season: .winter)
        }
    }

    /// A student who chose the maple ring in the Fall keeps it in the Winter:
    /// saving the form again with the same ring is allowed.
    @Test func aStudentKeepsASeasonalRingAfterItsTerm() throws {
        var wearing = Self.base
        wearing.border = .maple
        let updated = try AvatarCustomization.applying(
            ["backdrop": "rose", "border": "maple"], to: wearing, isStaff: false, season: .winter)
        #expect(updated.border == .maple)
        #expect(updated.backdrop == .rose)
    }

    /// Keeping a worn ring does not open a locked one: the exception is only
    /// for the ring already worn.
    @Test func keepingAWornRingOpensNoOtherRing() {
        var wearing = Self.base
        wearing.border = .maple
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .border, value: "blossom")) {
            try AvatarCustomization.applying(
                ["border": "blossom"], to: wearing, isStaff: false, season: .winter)
        }
    }

    @Test func staffCannotChooseASeasonalRing() {
        #expect(throws: AvatarCustomizationError.staffRingIsFixed) {
            try AvatarCustomization.applying(
                ["border": "maple"], to: Self.base, isStaff: true, season: .fall)
        }
    }
}
