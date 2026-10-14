import Core
import Testing

/// The colourway slot in the customization chokepoint: the species is drawn,
/// not chosen, so a colourway is open only within the student's own species,
/// and a colourway of another species is refused with nothing changed.
@Suite struct AvatarSpeciesPickerTests {

    private static let base = AvatarSpec(
        cap: .teal, wing: .barred, expression: .wink, accessory: .scarf, accent: .honey,
        backdrop: .rose, tuft: .crest, tilt: .left, border: .moss)

    @Test(arguments: AvatarSpecies.allCases)
    func theColourwaySlotOffersExactlyTheOwnSpeciesColourways(species: AvatarSpecies) {
        #expect(AvatarCustomization.options(for: .cap, species: species) == species.colourways.map(\.rawValue))
        for cap in AvatarCap.allCases {
            #expect(
                AvatarCustomization.isOpen(cap.rawValue, for: .cap, species: species)
                    == (AvatarSpecies.of(cap) == species), "\(cap) for \(species)")
        }
        #expect(!AvatarCustomization.isOpen("chartreuse", for: .cap, species: species))
    }

    /// With no species named, no colourway is open: the safe answer.
    @Test func withNoSpeciesNoColourwayIsOpen() {
        #expect(AvatarCustomization.options(for: .cap).isEmpty)
        #expect(!AvatarCustomization.isOpen("teal", for: .cap))
    }

    @Test func choosingAnOwnSpeciesColourwayChangesOnlyTheColourway() throws {
        let updated = try AvatarCustomization.applying(["cap": "plum"], to: Self.base, isStaff: false)
        var expected = Self.base
        expected.cap = .plum
        #expect(updated == expected, "a slot other than the colourway changed")
        #expect(updated.species == .chickadee)
    }

    @Test func anotherSpeciesColourwayIsRefusedAndChangesNothing() {
        for cap in AvatarCap.allCases where AvatarSpecies.of(cap) != Self.base.species {
            #expect(throws: AvatarCustomizationError.colourwayChangesSpecies(value: cap.rawValue)) {
                try AvatarCustomization.applying(
                    ["cap": cap.rawValue, "backdrop": "sky"], to: Self.base, isStaff: false)
            }
        }
    }

    @Test func aColourwayCanBeChosenBesideTheOtherSlots() throws {
        let updated = try AvatarCustomization.applying(
            ["cap": "ink", "backdrop": "sky", "border": "rainbow"], to: Self.base, isStaff: false)
        #expect(updated.cap == .ink)
        #expect(updated.backdrop == .sky)
        #expect(updated.border == .rainbow)
    }

    @Test func anUnknownColourwayIsRefusedAndChangesNothing() {
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .cap, value: "chartreuse")) {
            try AvatarCustomization.applying(["cap": "chartreuse", "backdrop": "sky"], to: Self.base, isStaff: false)
        }
        // Raw values are exact: the picker posts them as the enum spells them.
        #expect(throws: AvatarCustomizationError.unknownOption(slot: .cap, value: "Plum")) {
            try AvatarCustomization.applying(["cap": "Plum"], to: Self.base, isStaff: false)
        }
    }

    /// Staff cannot change their ring, but the colour is theirs to choose,
    /// within their species, like a student's.
    @Test func staffMayChooseAnOwnSpeciesColourwayOnly() throws {
        var cardinal = Self.base
        cardinal.cap = .scarlet
        let updated = try AvatarCustomization.applying(["cap": "fawn"], to: cardinal, isStaff: true)
        #expect(updated.cap == .fawn)
        #expect(throws: AvatarCustomizationError.colourwayChangesSpecies(value: "emerald")) {
            try AvatarCustomization.applying(["cap": "emerald"], to: cardinal, isStaff: true)
        }
    }

    /// The tuft layer a crested colourway would draw follows the student's
    /// own tuft slot (as a crest shape) and hat: the picker's samples and live
    /// preview carry exactly what a save would render.
    @Test func aCrestedColourwayPresentsTheCrestShapeOfTheTuftSlot() {
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
