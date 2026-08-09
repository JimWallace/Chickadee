// APIServer/Routes/Web/NewAssignmentFormContext.swift
//
// The five form fields the new-assignment page round-trips through every
// redirect back to itself, plus the one builder that turns them into that URL.

import Foundation

/// The subset of the new-assignment form that has to survive a bounce back to
/// `/instructor/new` so the page re-renders with what the instructor typed
/// rather than an empty form.
///
/// These five travelled as five separate parameters through three functions,
/// two of which tripped `function_parameter_count`.  More to the point, two of
/// those functions each built the same query string with the same five fields
/// in a different order — a second spelling of one thing, which is how the
/// instructor dashboard's two item tables came to disagree (#1253).  There is
/// one builder here and no second spelling.
struct NewAssignmentFormContext {
    let title: String
    let dueAt: String
    let startsAt: String
    let sectionID: String
    let draftID: String

    /// Builds the `/instructor/new?…` URL that bounces the instructor back to
    /// the page, optionally carrying a notice or a user-visible error.
    ///
    /// Field order is `draftID` first because `AssignmentRoutesPublishTests`
    /// matched on that prefix before this type existed; nothing else depends
    /// on the order, and a correct consumer reads these by name.  An empty
    /// notice or error is omitted rather than emitted as a bare `error=` —
    /// previously true of one caller and not the other.
    func redirectURL(notice: String? = nil, error: String? = nil) -> String {
        var parts: [String] = [
            "draftID=\(urlEncode(draftID))",
            "assignmentName=\(urlEncode(title))",
            "dueAt=\(urlEncode(dueAt))",
            "startsAt=\(urlEncode(startsAt))",
            "sectionID=\(urlEncode(sectionID))",
        ]
        if let notice, !notice.isEmpty {
            parts.append("notice=\(urlEncode(notice))")
        }
        if let error, !error.isEmpty {
            parts.append("error=\(urlEncode(error))")
        }
        return "/instructor/new?\(parts.joined(separator: "&"))"
    }
}
