// Tests/CoreTests/AvatarDrawWeightTests.swift

import Core
import Testing

/// The first-use draw weights three slots (docs/avatar-species.md, "Trait
/// weights"): most birds upright, bare-headed and wearing nothing. Everything
/// else stays uniform, and every option stays reachable.
@Suite struct AvatarDrawWeightTests {

    private static let draws = 20_000

    private static func share(_ matches: (AvatarSpec) -> Bool) -> Double {
        var count = 0
        for seed in 0..<UInt64(draws) where matches(AvatarSpec.drawn(fromSeed: seed)) { count += 1 }
        return Double(count) / Double(draws)
    }

    private static func expectedShare<T>(of option: T, among options: [T], weight: (T) -> Int) -> Double
    where T: Equatable {
        Double(weight(option)) / Double(options.reduce(0) { $0 + weight($1) })
    }

    @Test func mostBirdsStandUpright() {
        let expected = Self.expectedShare(of: .upright, among: AvatarTilt.allCases, weight: \.drawWeight)
        #expect(expected == 0.8)
        #expect(abs(Self.share { $0.tilt == .upright } - expected) < 0.02)
        #expect(abs(Self.share { $0.tilt == .left } - 0.1) < 0.02)
    }

    @Test func mostBirdsHaveABareHead() {
        let expected = Self.expectedShare(of: .none, among: AvatarTuft.allCases, weight: \.drawWeight)
        #expect(expected == 0.6)
        #expect(abs(Self.share { $0.tuft == .none } - expected) < 0.02)
        #expect(abs(Self.share { $0.tuft == .swoop } - 0.1) < 0.02)
    }

    @Test func aboutAThirdOfBirdsWearNothing() {
        let expected = Self.expectedShare(
            of: .none, among: AvatarAccessory.starterCases, weight: \.drawWeight)
        #expect(abs(expected - 4.0 / 11.0) < 0.001)
        #expect(abs(Self.share { $0.accessory == .none } - expected) < 0.02)
        #expect(abs(Self.share { $0.accessory == .scarf } - 1.0 / 11.0) < 0.02)
    }

    /// A weight of one is still a weight: every tilt and tuft stays reachable.
    @Test func everyWeightedOptionIsStillDrawn() {
        for tilt in AvatarTilt.allCases {
            #expect(Self.share { $0.tilt == tilt } > 0.05, "\(tilt)")
        }
        for tuft in AvatarTuft.allCases {
            #expect(Self.share { $0.tuft == tuft } > 0.05, "\(tuft)")
        }
        for accessory in AvatarAccessory.starterCases {
            #expect(Self.share { $0.accessory == accessory } > 0.05, "\(accessory)")
        }
    }

    /// The gradcap is not a starter, so its weight never enters the draw.
    @Test func theDrawNeverPicksAnUnlockable() {
        #expect(Self.share { $0.accessory == .gradcap } == 0)
        #expect(Self.share { AvatarExpression.starterCases.contains($0.expression) } == 1)
    }

    @Test func theUniformSlotsStayUniform() {
        for wing in AvatarWing.allCases {
            #expect(abs(Self.share { $0.wing == wing } - 1.0 / 6.0) < 0.02, "\(wing)")
        }
        for backdrop in AvatarBackdrop.allCases {
            #expect(abs(Self.share { $0.backdrop == backdrop } - 1.0 / 8.0) < 0.02, "\(backdrop)")
        }
        for expression in AvatarExpression.starterCases {
            #expect(abs(Self.share { $0.expression == expression } - 1.0 / 6.0) < 0.02, "\(expression)")
        }
    }

    @Test func theLateAxisFillUsesTheSameWeights() {
        var upright = 0
        let fills = 5_000
        for seed in 0..<UInt64(fills) {
            var generator = AvatarSeedGenerator(seed: seed)
            let base = AvatarSpec.drawn(fromSeed: 1)
            if base.fillingMissing([.tilt], using: &generator).tilt == .upright { upright += 1 }
        }
        #expect(abs(Double(upright) / Double(fills) - 0.8) < 0.03)
    }
}
