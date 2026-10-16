// APIServer/Services/AvatarIconKey.swift
//
// The path segment that names one tab icon (docs/student-avatars.md, "The tab
// icon"): the fields the icon draws, in a fixed order, joined by dots. For
// example "chickadee.teal.barred.bright.cowlick.scarf.honey.sky".
//
// The key holds only what the leaderboard already shows, and no user id, so
// the icon route needs no session. The ring and the tilt are not in it,
// because the icon draws neither. A change to any field the icon draws
// changes the URL, so an immutable cache never shows an old bird.

import Core

enum AvatarIconKey {
    /// The house bird: the icon for a signed-out page, a user with no bird
    /// yet, an LMS frame and Present mode.
    static let houseSpec = AvatarSpec(
        cap: .ink, wing: .plain, expression: .bright, accessory: .none, accent: .lagoon, backdrop: .aqua)

    static let house = encode(houseSpec)

    /// Species, colourway, wing, expression, tuft, accessory, accent, backdrop.
    /// The species follows from the colourway; it is in the key so that the
    /// URL reads as the bird it draws.
    static func encode(_ spec: AvatarSpec) -> String {
        [
            spec.species.rawValue, spec.cap.rawValue, spec.wing.rawValue, spec.expression.rawValue,
            spec.tuft.rawValue, spec.accessory.rawValue, spec.accent.rawValue, spec.backdrop.rawValue,
        ].joined(separator: ".")
    }

    /// The spec a key names, upright and with no ring, or nil when a field is
    /// not a current raw value of its enum or the species does not match the
    /// colourway.
    static func decode(_ key: String) -> AvatarSpec? {
        let fields = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 8,
            let species = AvatarSpecies(rawValue: fields[0]),
            let cap = AvatarCap(rawValue: fields[1]),
            AvatarSpecies.of(cap) == species,
            let wing = AvatarWing(rawValue: fields[2]),
            let expression = AvatarExpression(rawValue: fields[3]),
            let tuft = AvatarTuft(rawValue: fields[4]),
            let accessory = AvatarAccessory(rawValue: fields[5]),
            let accent = AvatarAccent(rawValue: fields[6]),
            let backdrop = AvatarBackdrop(rawValue: fields[7])
        else { return nil }
        return AvatarSpec(
            cap: cap, wing: wing, expression: expression, accessory: accessory,
            accent: accent, backdrop: backdrop, tuft: tuft)
    }

    /// The icon's URL. The version is the app version, so a release that
    /// changes the art also changes every URL.
    static func path(version: String, key: String) -> String {
        "/avatar-icon/\(version)/\(key).svg"
    }
}
