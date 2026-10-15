// APIServer/Routes/Web/AvatarHatchContext.swift
//
// The hatch control on the account page's bird card, and the strip across the
// top of the card that confirms a hatch or shows its result
// (Core/AvatarHatch.swift).

import Core
import Foundation

/// Which strip the bird card shows across its top.
enum AvatarHatchStrip: String, Encodable {
    /// "Hatch a new bird?": `GET /account?hatch=confirm`.
    case confirm
    /// "Meet your new bird": the redirect after a hatch.
    case hatched
}

struct AvatarHatchContext: Encodable {
    /// Hatches left this term.
    let left: Int
    /// "3 of 3 left this term", or, at none, when more come.
    let caption: String
    /// The strip to show, if any.
    let strip: AvatarHatchStrip?
    /// The current bird at the strip's size.
    let current: AvatarPresentation
    /// "cardinal": the current species, lowercase for a sentence.
    let speciesWord: String
    /// "a blue jay": the current species with its article.
    let speciesWithArticle: String
    /// The bird before the last hatch, at the small size, while the student
    /// can go back to it.
    let previous: AvatarPresentation?
    /// "cardinal": the previous species, lowercase for a sentence.
    let previousSpeciesWord: String?
    /// The bird's handle; nil for a bird with none (course staff), whose
    /// hatch draws no name.
    let handle: String?
    /// The previous bird's handle, for the way back; nil when it had none.
    let previousHandle: String?

    var canHatch: Bool { left > 0 }

    /// `requested` is the strip the request asked for. A confirm needs a hatch
    /// left, and a hatched strip needs a previous bird to go back to;
    /// otherwise no strip shows.
    init(
        spec: AvatarSpec, handle: String?, status: AvatarHatchStatus, nextTerm: AcademicTerm?,
        requested: AvatarHatchStrip?, isStaff: Bool
    ) {
        self.handle = handle
        previousHandle = status.previousHandle
        left = status.left
        caption = Self.caption(left: status.left, nextTerm: nextTerm)
        current = AvatarPresentation(for: spec, size: .standard, accessibility: .decorative, isStaff: isStaff)
        speciesWord = Self.word(spec.species)
        speciesWithArticle = Self.withArticle(spec.species)
        previous = status.previous.map {
            AvatarPresentation(for: $0, size: .small, accessibility: .decorative, isStaff: isStaff)
        }
        previousSpeciesWord = status.previous.map { Self.word($0.species) }
        switch requested {
        case .confirm: strip = status.left > 0 ? .confirm : nil
        case .hatched: strip = status.previous != nil ? .hatched : nil
        case nil: strip = nil
        }
    }

    /// "Meet your new bird: Curious Noether, a blue jay."
    var meetTitle: String {
        guard let handle else { return "Meet your new bird: \(speciesWithArticle)." }
        return "Meet your new bird: \(handle), \(speciesWithArticle)."
    }

    /// What classmates see now, and the way back to the previous bird and,
    /// when it had one, its handle.
    var meetBody: String {
        let back =
            previousHandle.map { "\($0), your \(previousSpeciesWord ?? "bird")" }
            ?? "your \(previousSpeciesWord ?? "bird")"
        let seen = handle == nil ? "it" : "it and its handle"
        return "Classmates see \(seen) from now on. You can go back to \(back) until you hatch again."
    }

    /// "2 of 3 left this term"; at none, "None left this term. 3 more when
    /// Winter 2027 starts."
    static func caption(left: Int, nextTerm: AcademicTerm?) -> String {
        guard left == 0 else { return "\(left) of \(AvatarHatch.perTerm) left this term" }
        guard let nextTerm else { return "None left this term." }
        return "None left this term. \(AvatarHatch.perTerm) more when \(nextTerm.displayName) starts."
    }

    /// The species as a sentence names it: "blue jay".
    static func word(_ species: AvatarSpecies) -> String {
        species.displayName.lowercased()
    }

    /// "a blue jay", "an owl": "an" before a vowel.
    static func withArticle(_ species: AvatarSpecies) -> String {
        let word = word(species)
        let article = word.first.map { "aeiou".contains($0) } == true ? "an" : "a"
        return "\(article) \(word)"
    }
}
