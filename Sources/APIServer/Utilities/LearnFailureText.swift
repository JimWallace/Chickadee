// APIServer/Utilities/LearnFailureText.swift
//
// The sentence a staff page shows when a call to LEARN (BrightSpace) fails
// (UI audit #3007, finding 7). The pages used to print the Swift error, an
// HTTP status and a D2L body prefix. The raw error still goes to the log at
// each call site; the page says what happened and what to do next.

/// One sentence for a failed LEARN call, chosen by what the reader can do
/// about it. `action` names the call ("read the grade book").
func learnFailureText(_ error: any Error, action: String) -> String {
    guard let syncError = error as? BrightSpaceSyncError else {
        return "Couldn't \(action): LEARN did not answer. Try again in a few minutes."
    }
    switch syncError {
    case .notConfigured:
        return "Couldn't \(action): LEARN is not set up on this server. An admin sets it up on the LEARN tab."
    default:
        switch syncError.httpStatus {
        case 401, 403:
            return "Couldn't \(action): LEARN refused the server's credentials. An admin can authorize again."
        case 404:
            return "Couldn't \(action): LEARN has no course with this ID. Check the course's LEARN link."
        default:
            return "Couldn't \(action): LEARN reported an error. Try again in a few minutes."
        }
    }
}

extension BrightSpaceSyncError {
    /// The HTTP status D2L answered with; nil for a failure with none.
    var httpStatus: Int? {
        switch self {
        case .notConfigured, .userNotFound, .missingPoints: nil
        case .userLookupFailed(_, let status), .gradePushFailed(let status, _), .whoamiFailed(let status, _),
            .orgUnitLookupFailed(_, let status), .gradeObjectsFetchFailed(_, let status),
            .classlistFetchFailed(_, let status), .groupCategoriesFetchFailed(_, let status),
            .groupsFetchFailed(_, _, let status), .sectionsFetchFailed(_, let status):
            status
        }
    }
}
