// APIServer/LTI/LTILaunchValidator.swift
//
// The claim rules every LTI 1.3 launch must pass (docs/lti-1-3.md "Launch
// validation"). Pure: the caller verifies the signature against the
// platform's key set first, then passes the decoded claims, the registration
// and the clock here. Single use of the nonce is the caller's job too — it
// needs the database — so this checks only that one is present.

import Core
import Foundation
import JWT

enum LTILaunchValidator {
    static let supportedVersion = "1.3.0"

    static func validate(
        _ claims: LTILaunchClaims,
        against platform: LTIPlatformRegistration,
        now: Date
    ) throws(LTILaunchError) -> LTIValidatedLaunch {
        guard claims.iss.value == platform.issuer else { throw .issuerMismatch }

        let audiences = claims.aud.value
        guard audiences.contains(platform.clientID) else { throw .audienceMismatch }
        // With several audiences, `azp` must name us. With one, it is optional
        // but must still match when sent.
        if audiences.count > 1 || claims.azp != nil {
            guard claims.azp == platform.clientID else { throw .authorizedPartyMismatch }
        }

        guard let deploymentID = claims.deploymentID,
            platform.deploymentIDs.contains(deploymentID)
        else { throw .unknownDeployment }

        guard claims.version == supportedVersion else { throw .unsupportedVersion }
        guard let rawType = claims.messageType,
            let messageType = LTIValidatedLaunch.MessageType(rawValue: rawType)
        else { throw .unsupportedMessageType }

        guard let nonce = nonEmpty(claims.nonce) else { throw .missingNonce }
        guard let subject = nonEmpty(claims.sub?.value) else { throw .missingSubject }

        let skew = LTILaunchClaims.clockSkewSeconds
        guard claims.exp.value > now.addingTimeInterval(-skew) else { throw .expired }
        guard claims.iat.value <= now.addingTimeInterval(skew) else { throw .issuedInFuture }

        if messageType == .resourceLink {
            guard nonEmpty(claims.context?.id) != nil else { throw .missingContext }
            guard nonEmpty(claims.resourceLink?.id) != nil else { throw .missingResourceLink }
        }

        guard let courseRole = LTIRoleMapping.courseRole(forRoles: claims.roles ?? []) else {
            throw .noCourseRole
        }

        return LTIValidatedLaunch(
            messageType: messageType,
            subject: subject,
            nonce: nonce,
            deploymentID: deploymentID,
            courseRole: courseRole,
            context: claims.context,
            resourceLink: claims.resourceLink,
            name: claims.name,
            email: claims.email,
            custom: claims.custom ?? [:],
            deepLinkingSettings: claims.deepLinkingSettings
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
