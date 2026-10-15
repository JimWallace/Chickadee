// Core/AvatarLifeList.swift
//
// A birder keeps a "life list" of the species they have seen. A student's
// life list is the species their birds have been (#2593): the bird now, the
// bird before the last hatch, and every species a recorded hatch came from or
// went to. A hatch row made before species were recorded adds nothing; no
// species is guessed. The list is private: the account page only.

public enum AvatarLifeList {

    /// The species a student has had, from the current bird, the bird before
    /// the last hatch, and each hatch's species, from and to (nil when that
    /// hatch row predates the record).
    public static func seen(
        current: AvatarSpecies?, previous: AvatarSpecies?,
        hatches: [(from: AvatarSpecies?, to: AvatarSpecies?)]
    ) -> Set<AvatarSpecies> {
        var species = Set([current, previous].compactMap(\.self))
        for hatch in hatches {
            if let from = hatch.from { species.insert(from) }
            if let to = hatch.to { species.insert(to) }
        }
        return species
    }

    /// The bird that stands for `species` on the life list: the species' first
    /// colourway, bare and upright, with a bright face, on the sky backdrop,
    /// so the entries differ only by species.
    public static func bird(for species: AvatarSpecies) -> AvatarSpec {
        AvatarSpec(
            cap: species.colourways.first ?? .ink, wing: .plain, expression: .bright, accessory: .none, accent: .ember,
            backdrop: .sky, tuft: .none, tilt: .upright, border: .none)
    }
}
