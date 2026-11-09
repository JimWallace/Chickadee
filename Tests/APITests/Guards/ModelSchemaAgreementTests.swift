// Tests/APITests/Guards/ModelSchemaAgreementTests.swift
//
// Every Fluent model agrees with the migrated table it reads. The `Add*`
// migrations are folded into the `Create*` files from time to time, and a
// fold can change a column's nullability without anyone noticing: a model
// that declares a non-optional field over a nullable column fails to decode
// the first NULL row, on whatever page reads it.
//
// The fields come from Fluent's own property reflection, not from the Swift
// text, and the columns from the catalog of the migrated test schema.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// Whether a Fluent property's Swift type can hold a missing value.
private protocol NullabilityDeclaring {
    static var acceptsNull: Bool { get }
}

extension FieldProperty: NullabilityDeclaring {
    fileprivate static var acceptsNull: Bool { Value.self is any ExpressibleByNilLiteral.Type }
}

extension OptionalFieldProperty: NullabilityDeclaring {
    fileprivate static var acceptsNull: Bool { true }
}

extension TimestampProperty: NullabilityDeclaring {
    fileprivate static var acceptsNull: Bool { true }
}

/// The primary key, which the check skips: Fluent declares it optional
/// because a new model has none yet.
private protocol PrimaryKeyProperty {}

extension IDProperty: PrimaryKeyProperty {}

extension ParentProperty: NullabilityDeclaring {
    fileprivate static var acceptsNull: Bool { false }
}

@Suite(.serialized, .timeLimit(.minutes(5)))
struct ModelSchemaAgreementTests {

    /// Every Fluent model the server registers. `everyTableHasAModel` fails
    /// when a new table has no entry here.
    static let models: [any Model.Type] = [
        APIAchievementAward.self, APIAchievementResult.self, APIActivityChampion.self,
        APIActivitySession.self, APIActivitySessionAttendance.self, APIActivityStanding.self,
        APIAssignment.self, APIAssignmentExtension.self, APIAssignmentParticipation.self,
        APIAssignmentPersonalizationSeed.self, APIAssignmentVersion.self, APIAuditLogEntry.self,
        APIAvatarHatch.self, APIBrightSpaceCredential.self, APIBrightSpaceGradeClear.self,
        APIBrightSpaceSyncLog.self, APIClassAchievement.self, APIClassCoverageRun.self,
        APIClassItemCoverage.self, APIClientDiagnostic.self, APICompositeContribution.self,
        APICompositeReference.self, APICompositeSlot.self, APICompositeSpare.self, APICourse.self,
        APICourseContentItem.self, APICourseDataset.self, APICourseDatasetVersion.self,
        APICourseEnrollment.self, APICourseGroup.self, APICourseGroupMembership.self,
        APICourseGroupSet.self, APICoursePersonalizationSeed.self, APICourseSection.self,
        APIDataExport.self, APIDatasetDeal.self, APIGitHubAccountLink.self, APIGitHubApp.self,
        APIGitHubAssignmentTemplate.self, APIGitHubCourseOrganization.self,
        APIGitHubCourseRepository.self, APIGradeOverride.self, APIGroupAchievementResult.self,
        APIGroupActivityChampion.self, APIGroupClassItemCoverage.self, APIGroupCompositeSlot.self,
        APIGroupCompositeSpare.self, APIGroupLeaderboardEntry.self, APILTIDeepLinkRequest.self,
        APILTIGradeSync.self, APILTIIdentity.self, APILTILoginState.self, APILTIPlatform.self,
        APILeaderboardEntry.self, APIMatchResult.self, APIPreEnrollment.self,
        APIReflectionFeedback.self, APIRequestMetric.self, APIResult.self, APIResultCollection.self,
        APISecretRevealUnlock.self, APISlipDaySpend.self, APISubmission.self,
        APISubmissionDiagnostics.self, APITestSetup.self, APITournamentMatch.self,
        APITournamentRun.self, APIUser.self, APIUserActivityEvent.self, APIWardrobeUnlock.self,
        AssignmentRequirement.self, JobExecutionMetric.self, LoginAttempt.self,
        MCPAuthorizationCode.self, MCPConsentRequest.self, MCPGrant.self, MCPOAuthClient.self,
        RunnerProfile.self, RunnerSnapshot.self, SweepLease.self, ValidationVariant.self,
        WorkerNonce.self,
    ]

    /// Only one direction of disagreement is checked. An optional field over
    /// a NOT NULL column is common and safe (every `@Timestamp` is optional
    /// in Swift): it reads every row, and a write of nil fails loudly. A
    /// non-optional field over a nullable column fails to decode the first
    /// NULL row; make the column NOT NULL, as `RequireAssignmentSlug` did.
    @Test func everyFieldHasAColumnThatAgreesOnNull() async throws {
        try await withTestApp(prefix: "chickadee-model-schema") { app in
            let catalog = try await SchemaCatalog.load(on: app.db)
            let columns = Dictionary(
                catalog.columns.map { ($0.qualified, $0) }, uniquingKeysWith: { first, _ in first })

            var missing: [String] = []
            var disagreeing: [String] = []
            var unknownProperties: [String] = []
            for model in Self.models {
                for property in model.init().properties {
                    // A relation such as `@Children` has no column of its own.
                    guard let database = property as? any AnyDatabaseProperty,
                        !database.keys.isEmpty,
                        !(property is any PrimaryKeyProperty)
                    else { continue }
                    guard let declaring = type(of: property) as? any NullabilityDeclaring.Type else {
                        unknownProperties.append("\(model).\(type(of: property))")
                        continue
                    }
                    for key in database.keys {
                        let name = "\(model.schema).\(key.description)"
                        guard let column = columns[name] else {
                            missing.append(name)
                            continue
                        }
                        if !declaring.acceptsNull && column.isNullable {
                            disagreeing.append("\(name): non-optional in \(model), nullable in the schema")
                        }
                    }
                }
            }
            #expect(unknownProperties.isEmpty, "teach NullabilityDeclaring these: \(unknownProperties)")
            #expect(missing.isEmpty, "fields with no column: \(missing.sorted())")
            #expect(
                disagreeing.isEmpty,
                "a NULL row fails to decode; make the column NOT NULL or the field optional: \(disagreeing.sorted())")
        }
    }

    @Test func everyTableHasAModel() async throws {
        try await withTestApp(prefix: "chickadee-model-tables") { app in
            let catalog = try await SchemaCatalog.load(on: app.db)
            let modelled = Set(Self.models.map { $0.schema })
            let unmodelled = catalog.tables.subtracting(modelled)
            #expect(
                unmodelled.isEmpty, "tables with no entry in ModelSchemaAgreementTests.models: \(unmodelled.sorted())")
            let gone = modelled.subtracting(catalog.tables).filter { !$0.hasPrefix("_fluent") }
            #expect(gone.isEmpty, "models whose table is not migrated: \(gone.sorted())")
        }
    }
}
