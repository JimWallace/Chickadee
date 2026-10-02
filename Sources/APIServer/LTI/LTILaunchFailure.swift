// APIServer/LTI/LTILaunchFailure.swift
//
// Why an LTI login or launch stopped (docs/lti-1-3.md "Launch"). Each case
// is an `AbortError`, so the existing error page renders it with its status
// and one sentence; `logDetail` is what the server log records, and it names
// the rule without echoing any token.

import Vapor

enum LTILaunchFailure: AbortError, Equatable {
    case missingLoginParameters
    case unknownPlatform
    case ambiguousPlatform
    case missingLaunchParameters
    case platformReportedError(String)
    case stateCookieMissing
    case stateUnknown
    case stateExpired
    case platformDisabled
    case tokenInvalid
    case claimRejected(LTILaunchError)
    case nonceMismatch
    case linkRefused
    case deepLinkingUnsupported
    case deepLinkingNotAllowed
    case courseNotLinked
    case deepLinkCourseNotLinked

    var status: HTTPResponseStatus {
        switch self {
        case .missingLoginParameters, .missingLaunchParameters, .ambiguousPlatform, .platformReportedError,
            .deepLinkingUnsupported:
            .badRequest
        case .unknownPlatform, .platformDisabled: .forbidden
        case .stateCookieMissing, .stateUnknown, .stateExpired, .tokenInvalid, .claimRejected,
            .nonceMismatch:
            .unauthorized
        case .linkRefused, .courseNotLinked, .deepLinkCourseNotLinked, .deepLinkingNotAllowed: .forbidden
        }
    }

    var reason: String {
        switch self {
        case .missingLoginParameters, .missingLaunchParameters:
            "The LMS sent an incomplete launch request. Open the link from the LMS again."
        case .unknownPlatform, .platformDisabled:
            "Chickadee does not accept launches from this LMS. Ask an administrator to check its registration."
        case .ambiguousPlatform:
            "More than one registration matches this LMS. Ask an administrator to check the LTI settings."
        case .platformReportedError:
            "The LMS could not complete the sign-in. Open the link from the LMS again."
        case .stateCookieMissing:
            "Your browser did not keep the sign-in cookie. Ask your instructor to set the LMS link to open in a new window."
        case .stateUnknown, .stateExpired, .tokenInvalid, .claimRejected, .nonceMismatch:
            "The launch could not be verified. Open the link from the LMS again."
        case .linkRefused:
            "This LMS account cannot sign in to the matching Chickadee account. Ask an administrator to check the account."
        case .deepLinkingUnsupported:
            "This LMS asked for content that Chickadee cannot provide. Ask an administrator to check the LTI settings."
        case .deepLinkingNotAllowed:
            "Only course staff can add Chickadee content to the LMS."
        case .courseNotLinked:
            "This LMS course is not linked to a Chickadee course yet. Ask your instructor to open the link once."
        case .deepLinkCourseNotLinked:
            "This LMS course is not linked to a Chickadee course yet. Ask an instructor of the course to add Chickadee content once to link it."
        }
    }

    /// The server-log line: which rule stopped the launch.
    var logDetail: String {
        switch self {
        case .platformReportedError(let code): "platform returned error=\(code)"
        case .claimRejected(let error): "claim rule failed: \(error)"
        default: "\(self)"
        }
    }
}
