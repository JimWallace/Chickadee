// APIServer/Routes/Web/CourseTermForm.swift
//
// The year and term fields of the course forms (docs/course-terms.md): the
// options the term select renders, and the parse of what a form posted.

import Core
import Foundation

/// One `<option>` of the term select.
struct CourseTermOption: Encodable {
    let value: String
    let label: String
    let selected: Bool
}

/// What a course form posted for its term.
enum CourseTermInput: Equatable {
    /// Neither field was posted (an older client, or a form without them).
    case absent
    /// Both fields were posted and make a valid term.
    case term(AcademicTerm)
    /// The fields were posted but do not make a valid term: one is blank,
    /// the year is not four digits, or the season is unknown.
    case invalid

    init(year rawYear: String?, season rawSeason: String?) {
        let year = rawYear?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let season = rawSeason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawYear == nil, rawSeason == nil {
            self = .absent
            return
        }
        guard
            let yearValue = Int(year),
            let seasonValue = TermSeason(rawValue: season),
            let term = AcademicTerm(year: yearValue, season: seasonValue)
        else {
            self = .invalid
            return
        }
        self = .term(term)
    }
}

enum CourseTermForm {
    /// The three seasons in calendar order, with `selected` marked.
    static func options(selected: TermSeason?) -> [CourseTermOption] {
        TermSeason.allCases.map {
            CourseTermOption(value: $0.rawValue, label: $0.displayName, selected: $0 == selected)
        }
    }
}

/// Why a clone form was refused. The admin clone section and the instructor
/// New term tab both use it, so the query code and the words are written
/// once (docs/course-terms.md slices 4 and 5).
enum CourseCloneFormError: String, CaseIterable {
    case fields = "clone_fields_required"
    case term = "clone_term_required"
    case codeTaken = "clone_code_taken"

    var message: String {
        switch self {
        case .fields: "Enter a code and a name for the new course."
        case .term: "Enter a four-digit year and a term for the new course."
        case .codeTaken: "An active course already uses this code in that term."
        }
    }

    /// The message for an `error` query value, or nil for any other value.
    static func message(forQuery value: String?) -> String? {
        value.flatMap(Self.init(rawValue:))?.message
    }
}
