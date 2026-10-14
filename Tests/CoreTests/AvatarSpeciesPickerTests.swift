import Core
import Testing

/// The colourway slot in the customization chokepoint (docs/avatar-species.md,
/// A2): choosing a colourway chooses the species, and nothing else changes.
@Suite struct AvatarSpeciesPickerTests {

    private static let base = AvatarSpec(
        cap: .teal, wing: .barred, expression: .wink, accessory: .scarf, accent: .honey,
        backdrop: .rose, tuft: .crest, tilt: .left, border: .moss)

    @Test func theColourwaySlotOffersEveryColourway() {
        #expect(AvatarCustomization.options(for: .cap) == AvatarCap.allCases.map(\.rawValue))
        for cap in AvatarCap.allCases {
            #expect(AvatarCustomization.isOpen(cap.rawValue, for: .cap))
        }
        #expect(!AvatarCustomization.isOpen("chartreuse", for: .cap))
    }

    @Test func choosingAColourwayChangesTheSpeciesAndNothingElse() throws {
        let robin = try AvatarCustomization.applying(["cap": "copper"], to: Self.base, isStaff: false)
        #expect(robin.cap == .copper)
        #expect(robin.species == .robin)
        var expected = Self.base
        expected.cap = .copper
        #expect(robin == expected, "a slot other than the colourway changed")
    }

    @Test func aColourwayCanBeChosenBesideTheOtherSlots() throws {
        let updated = try AvatarCustomization.applying(
            ["cap": "scarlet", "backdrop": "sky", "border": "rainbow"], to: Self.base, isStaff: false)
        #expect(updated.species == .cardinal)
        #expect(updated.backdrop == .sky)
        #expect(updated.border == .rainbow)
    }

    @Test func anUnknownColourwayIsRefusedAndChangesNothing() {
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .cap, value: "chartreuse")) {
            try AvatarCustomization.applying(["cap": "chartreuse", "backdrop": "sky"], to: Self.base, isStaff: false)
        }
        // Raw values are exact: the picker posts them as the enum spells them.
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .cap, value: "Scarlet")) {
            try AvatarCustomization.applying(["cap": "Scarlet"], to: Self.base, isStaff: false)
        }
    }

    /// Staff cannot change their ring, but the species is lateral and theirs
    /// to choose like the backdrop.
    @Test func staffMayChooseAColourway() throws {
        let updated = try AvatarCustomization.applying(["cap": "emerald"], to: Self.base, isStaff: true)
        #expect(updated.species == .starling)
    }

    /// The tuft layer a crested colourway would draw follows the student's
    /// own tuft and hat: the picker's samples and live preview carry exactly
    /// what a save would render.
    @Test func aCrestedColourwayPresentsTheCrestOnlyOnABareHead() {
        func tuft(_ cap: AvatarCap, tuft: AvatarTuft, accessory: AvatarAccessory) -> String {
            var spec = Self.base
            spec.cap = cap
            spec.tuft = tuft
            spec.accessory = accessory
            return AvatarPresentation(for: spec, size: .roster, accessibility: .decorative, isStaff: false)
                .tuftSymbolRef
        }
        #expect(tuft(.azure, tuft: .none, accessory: .none) == "#av-crest-bluejay")
        #expect(tuft(.azure, tuft: .crest, accessory: .none) == "#av-tuft-crest")
        #expect(tuft(.azure, tuft: .none, accessory: .beanie) == "#av-tuft-none")
    }
}
