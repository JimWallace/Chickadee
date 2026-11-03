// APIServer/Utilities/SubmissionEarnedItem.swift
//
// A wardrobe item the Earned toast shows (EarnedToast.swift): the result
// page's newly earned item, or the found Quantum Cats ring that the layout
// renders hidden (docs/student-wardrobe.md, 6c). It sits below Routes/
// because CurrentUserContext builds the second, and in Utilities/ because it
// uses no request, database or model.

import Core

/// The Earned toast on the student's own result page
/// (docs/result-celebration.md, J2): one new wardrobe item, the student's bird
/// wearing it, and what `POST /account/avatar` takes to wear it.
struct SubmissionEarnedItem: Encodable {
    /// The student's stored bird, wearing the new item.
    let bird: AvatarPresentation
    /// "New face" or "New ring".
    let chip: String
    /// "Chirp".
    let name: String
    /// "Earned by a first graded submission."
    let howEarned: String
    /// "New face earned: Chirp.", for the live region.
    let announcement: String
    /// The form field and value that wear the item: "expression", "chirp".
    let field: String
    let value: String
    /// A new ring draws in on the toast's bird; a new face crossfades.
    let isRing: Bool
    /// Where the ring starts to draw in, clockwise from the top.
    let ringStartDegrees: Int

    init(_ item: WardrobeItem, wearing spec: AvatarSpec, isStaff: Bool) {
        var wearing = spec
        switch item.slot {
        case .expression: wearing.expression = AvatarExpression(rawValue: item.value) ?? spec.expression
        case .border: wearing.border = AvatarBorder(rawValue: item.value) ?? spec.border
        case .backdrop: wearing.backdrop = AvatarBackdrop(rawValue: item.value) ?? spec.backdrop
        }
        bird = AvatarPresentation(for: wearing, size: .standard, accessibility: .decorative, isStaff: isStaff)
        let kind =
            switch item.slot {
            case .expression: "face"
            case .border: "ring"
            case .backdrop: "backdrop"
            }
        chip = "New \(kind)"
        name = item.displayName
        howEarned = "\(item.obtainedVerb) \(item.howEarned)."
        announcement = "New \(kind) \(item.obtainedVerb.lowercased()): \(item.displayName)."
        field = item.slot.rawValue
        value = item.value
        isRing = item.slot == .border
        ringStartDegrees = isRing ? wearing.border.ring.drawStartDegrees : 0
    }
}
