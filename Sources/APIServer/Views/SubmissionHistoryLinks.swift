// APIServer/Views/SubmissionHistoryLinks.swift
//
// The History cell's content on the staff submission tables: a link to the
// latest submission and a "+N more" link to the full history.

import Elementary

/// A link to the latest submission and to the rest, or "No submissions yet".
struct SubmissionHistoryLinks: HTML {
    let latest: LatestSubmissionCell
    let historyURL: String

    var body: some HTML {
        if latest.submissionCount > 0 {
            div(.class("submission-history-cell")) {
                if latest.hasLatestSubmission {
                    a(.href("/submissions/\(latest.latestSubmissionID)"), .class("submission-history-latest")) {
                        latest.latestSubmittedAtText
                    }
                }
                " "
                if latest.additionalSubmissionCount > 0 {
                    a(.href(historyURL), .class("submission-history-more")) {
                        "+\(latest.additionalSubmissionCount) more"
                    }
                }
            }
        } else {
            span(.class("empty")) { "No submissions yet" }
        }
    }
}
