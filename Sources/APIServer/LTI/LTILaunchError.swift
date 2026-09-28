// APIServer/LTI/LTILaunchError.swift
//
// Why `LTILaunchValidator` refused a launch. One case per rule, so a test can
// prove each rule on its own and the log names the rule that failed.

enum LTILaunchError: Error, Equatable, Sendable {
    case issuerMismatch
    case audienceMismatch
    case authorizedPartyMismatch
    case unknownDeployment
    case unsupportedVersion
    case unsupportedMessageType
    case missingNonce
    case missingSubject
    case expired
    case issuedInFuture
    case missingContext
    case missingResourceLink
    case noCourseRole
}
