import Core
import Testing

/// The face slot in the customization chokepoint (#2588): a student chooses
/// the bird's expression, and the species and colourway come with the bird.
/// The starter faces are open; the three unlockable faces are refused until
/// unlocks arrive, unless the bird already wears one.
@Suite struct AvatarExpressionPickerTests {

    private static let base = AvatarSpec(
        cap: .teal, wing: .barred, expression: .wink, accessory: .scarf, accent: .honey,
        backdrop: .rose, tuft: .crest, tilt: .left, border: .moss)

    @Test func theFaceSlotListsEveryExpressionAndOpensTheStarterFaces() {
        #expect(AvatarCustomization.options(for: .expression) == AvatarExpression.allCases.map(\.rawValue))
        for expression in AvatarExpression.allCases {
            #expect(
                AvatarCustomization.isOpen(expression.rawValue, for: .expression)
                    == AvatarExpression.starterCases.contains(expression), "\(expression)")
        }
        #expect(!AvatarCustomization.isOpen("grumpy", for: .expression))
    }

    @Test func choosingAStarterFaceChangesOnlyTheFace() throws {
        let updated = try AvatarCustomization.applying(["expression": "sleepy"], to: Self.base, isStaff: false)
        var expected = Self.base
        expected.expression = .sleepy
        #expect(updated == expected, "a slot other than the face changed")
    }

    @Test(arguments: [AvatarExpression.chirp, .sly, .dreamy])
    func anUnlockableFaceIsRefusedAndChangesNothing(face: AvatarExpression) {
        #expect(throws: AvatarCustomizationError.optionLocked(slot: .expression, value: face.rawValue)) {
            try AvatarCustomization.applying(
                ["expression": face.rawValue, "backdrop": "sky"], to: Self.base, isStaff: false)
        }
    }

    /// Saving the form again keeps a face the bird already wears, even one
    /// that is not open, as the worn ring is kept.
    @Test func theWornFaceIsAlwaysAccepted() throws {
        var chirping = Self.base
        chirping.expression = .chirp
        let updated = try AvatarCustomization.applying(
            ["expression": "chirp", "backdrop": "sky"], to: chirping, isStaff: false)
        #expect(updated.expression == .chirp)
        #expect(updated.backdrop == .sky)
    }

    @Test func aFaceCanBeChosenBesideTheOtherSlots() throws {
        let updated = try AvatarCustomization.applying(
            ["expression": "keen", "backdrop": "sky", "border": "rainbow"], to: Self.base, isStaff: false)
        #expect(updated.expression == .keen)
        #expect(updated.backdrop == .sky)
        #expect(updated.border == .rainbow)
    }

    @Test func anUnknownFaceIsRefusedAndChangesNothing() {
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .expression, value: "grumpy")) {
            try AvatarCustomization.applying(["expression": "grumpy", "backdrop": "sky"], to: Self.base, isStaff: false)
        }
        // Raw values are exact: the picker posts them as the enum spells them.
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .expression, value: "Sleepy")) {
            try AvatarCustomization.applying(["expression": "Sleepy"], to: Self.base, isStaff: false)
        }
    }

    /// The colourway is drawn, not chosen: `cap` is not a slot a student may
    /// change, and a request that names it changes nothing.
    @Test func theColourwayIsNotAChoice() {
        #expect(throws: AvatarCustomizationError.slotNotCustomizable("cap")) {
            try AvatarCustomization.applying(["cap": "plum", "backdrop": "sky"], to: Self.base, isStaff: false)
        }
    }

    /// Staff cannot change their ring, but the face is theirs to choose.
    @Test func staffMayChooseTheirFace() throws {
        let updated = try AvatarCustomization.applying(["expression": "curious"], to: Self.base, isStaff: true)
        #expect(updated.expression == .curious)
    }

    /// A hatch keeps the face, as it keeps the backdrop and the ring: the
    /// student chose all three.
    @Test(arguments: 0..<20 as Range<UInt64>)
    func aHatchKeepsTheChosenFace(seed: UInt64) {
        var sleepy = Self.base
        sleepy.expression = .sleepy
        let hatched = AvatarSpec.drawn(excluding: sleepy.species, keeping: sleepy, fromSeed: seed)
        #expect(hatched.expression == .sleepy)
        #expect(hatched.species != sleepy.species)
    }

    /// The tuft layer a crested bird draws follows the student's own tuft
    /// slot (as a crest shape) and hat: the picker's samples carry exactly
    /// what a save would render.
    @Test func aCrestedBirdPresentsTheCrestShapeOfTheTuftSlot() {
        func tuft(_ cap: AvatarCap, tuft: AvatarTuft, accessory: AvatarAccessory) -> String {
            var spec = Self.base
            spec.cap = cap
            spec.tuft = tuft
            spec.accessory = accessory
            return AvatarPresentation(for: spec, size: .roster, accessibility: .decorative, isStaff: false)
                .tuftSymbolRef
        }
        #expect(tuft(.azure, tuft: .none, accessory: .none) == "#av-crest-bluejay-swept")
        #expect(tuft(.azure, tuft: .crest, accessory: .none) == "#av-crest-bluejay-raised")
        #expect(tuft(.azure, tuft: .none, accessory: .beanie) == "#av-tuft-none")
    }
}
