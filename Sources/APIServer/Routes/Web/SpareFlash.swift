// APIServer/Routes/Web/SpareFlash.swift
//
// The result page's banner after "Fill a hole" (docs/class-composite.md,
// slice 6b). `WebRoutes.requestCompositeSpare` redirects with a code.

/// The answers to a "Fill a hole" request. The query carries a code, never
/// text, so a link cannot put words on the page.
enum SpareFlash: String {
    case queued, closed, noTile, grading, noHole, unavailable

    static func messages(for code: String?) -> FlashMessages {
        switch code.flatMap(SpareFlash.init(rawValue:)) {
        case .queued:
            FlashMessages(success: "Your request to fill a hole is queued.")
        case .closed:
            FlashMessages(error: "The class session is closed.")
        case .noTile:
            FlashMessages(error: "Your own tile must pass first.")
        case .grading:
            FlashMessages(error: "Your last spare tile is still grading.")
        case .noHole:
            FlashMessages(error: "Every slot is filled or is being filled.")
        case .unavailable:
            FlashMessages(error: "Your code could not be queued, so try again later.")
        case nil:
            FlashMessages()
        }
    }
}
