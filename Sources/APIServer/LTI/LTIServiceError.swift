// APIServer/LTI/LTIServiceError.swift
//
// Why an LTI service call (AGS, NRPS or the platform key set) failed, and
// whether the grade sweep tries it again.

import Foundation

enum LTIServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    enum Step: String, Sendable {
        case token = "access token"
        case findLineItem = "line item lookup"
        case createLineItem = "line item creation"
        case postScore = "score"
        case memberships = "membership"
        case keySet = "key set"
    }

    /// The platform answered one step with a non-success status.
    case rejected(Step, status: UInt)
    /// The platform answered with a body Chickadee cannot read.
    case unreadableResponse(Step)
    /// The line item Chickadee had on file is gone from the LMS.
    case lineItemGone
    /// A URL for one step names a host the admin did not register for the
    /// platform, so Chickadee did not call it.
    case foreignHost(Step)

    var description: String {
        switch self {
        case .rejected(let step, let status): "The LMS refused the \(step.rawValue) request (HTTP \(status))."
        case .unreadableResponse(let step): "The LMS sent an unreadable \(step.rawValue) response."
        case .lineItemGone: "The LMS grade item was deleted. Chickadee will find or create it again."
        case .foreignHost(let step): "The \(step.rawValue) address is not on a host registered for this LMS."
        }
    }

    /// True when the next sweep can succeed without a person doing anything.
    var isRetryable: Bool {
        switch self {
        case .rejected(_, let status): [401, 408, 425, 429, 500, 502, 503, 504].contains(status)
        case .unreadableResponse: false
        case .lineItemGone: true
        case .foreignHost: false
        }
    }
}
