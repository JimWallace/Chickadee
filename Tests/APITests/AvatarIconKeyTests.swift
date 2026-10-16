// Tests/APITests/AvatarIconKeyTests.swift
//
// The tab icon key (docs/student-avatars.md, "The tab icon") and the cache
// that holds the rendered icons.

import Core
import Testing

@testable import APIServer

@Suite struct AvatarIconKeyTests {
    @Test func theHouseBirdHasItsFixedKey() {
        #expect(AvatarIconKey.house == "chickadee.ink.plain.bright.none.none.lagoon.aqua")
    }

    @Test func gentleFernEncodesInTheFixedFieldOrder() {
        let spec = AvatarSpec(
            cap: .teal, wing: .barred, expression: .bright, accessory: .scarf, accent: .honey,
            backdrop: .sky, tuft: .cowlick)
        #expect(AvatarIconKey.encode(spec) == "chickadee.teal.barred.bright.cowlick.scarf.honey.sky")
    }

    @Test(arguments: AvatarCap.allCases)
    func everyKeyRoundTrips(cap: AvatarCap) {
        for wing in AvatarWing.allCases {
            for expression in AvatarExpression.allCases {
                for tuft in AvatarTuft.allCases {
                    let spec = AvatarSpec(
                        cap: cap, wing: wing, expression: expression, accessory: .bloom, accent: .moss,
                        backdrop: .pebble, tuft: tuft)
                    #expect(AvatarIconKey.decode(AvatarIconKey.encode(spec)) == spec)
                }
            }
        }
    }

    @Test func theRingAndTheTiltAreNotInTheKey() {
        let plain = AvatarSpec(
            cap: .scarlet, wing: .plain, expression: .keen, accessory: .glasses, accent: .ember, backdrop: .rose)
        var dressed = plain
        dressed.tilt = .right
        dressed.border = .rainbow
        #expect(AvatarIconKey.encode(dressed) == AvatarIconKey.encode(plain))
        #expect(AvatarIconKey.decode(AvatarIconKey.encode(dressed)) == plain)
    }

    @Test(arguments: [
        "", "chickadee.ink.plain.bright.none.none.lagoon",
        "chickadee.ink.plain.bright.none.none.lagoon.aqua.extra",
        "robin.ink.plain.bright.none.none.lagoon.aqua",
        "chickadee.chartreuse.plain.bright.none.none.lagoon.aqua",
        "chickadee.ink.striped.bright.none.none.lagoon.aqua",
        "chickadee.ink.plain.grumpy.none.none.lagoon.aqua",
        "chickadee.ink.plain.bright.mohawk.none.none.aqua",
        "chickadee.ink.plain.bright.none.cape.lagoon.aqua",
        "chickadee.ink.plain.bright.none.none.teal.aqua",
        "chickadee.ink.plain.bright.none.none.lagoon.night",
        "chickadee.ink.plain.bright.none.none.lagoon.Aqua",
    ])
    func aWrongFieldDecodesToNothing(key: String) {
        #expect(AvatarIconKey.decode(key) == nil)
    }

    @Test func thePathCarriesTheVersionAndTheKey() {
        #expect(
            AvatarIconKey.path(version: "0.5.1", key: AvatarIconKey.house)
                == "/avatar-icon/0.5.1/chickadee.ink.plain.bright.none.none.lagoon.aqua.svg")
    }

    // MARK: - The cache

    @Test func theCacheReturnsWhatWasInserted() {
        let cache = AvatarIconCache(capacity: 2)
        #expect(cache.svg(forKey: "a") == nil)
        cache.insert("<svg>a</svg>", forKey: "a")
        #expect(cache.svg(forKey: "a") == "<svg>a</svg>")
    }

    @Test func aFullCacheEvictsTheEntryUsedLongestAgo() {
        let cache = AvatarIconCache(capacity: 2)
        cache.insert("A", forKey: "a")
        cache.insert("B", forKey: "b")
        _ = cache.svg(forKey: "a")
        cache.insert("C", forKey: "c")
        #expect(cache.count == 2)
        #expect(cache.svg(forKey: "a") == "A")
        #expect(cache.svg(forKey: "b") == nil)
        #expect(cache.svg(forKey: "c") == "C")
    }
}
