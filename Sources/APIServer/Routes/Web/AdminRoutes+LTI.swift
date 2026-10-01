// APIServer/Routes/Web/AdminRoutes+LTI.swift
//
// Admin "LTI" tab (docs/lti-1-3.md slice 1b): the tool configuration values an
// LMS administrator needs, and the platform registrations Chickadee accepts
// launches from. Registrations live in `lti_platforms`, not in environment
// variables, so an admin adds or rotates one without a restart.
//
//   GET  /admin/lti                               → admin-lti.leaf
//   POST /admin/lti/platforms                     → register a platform
//   POST /admin/lti/platforms/:platformID         → edit a platform
//   POST /admin/lti/platforms/:platformID/enabled → enable or disable
//   POST /admin/lti/platforms/:platformID/delete  → delete

import Fluent
import Foundation
import Vapor

extension AdminRoutes {
    /// Post-redirect notices, as keys so a query string cannot put arbitrary
    /// text on the page.
    enum LTIAdminNotice: String {
        case registered, updated, enabled, disabled, deleted, deletedUnbound

        var message: String {
            switch self {
            case .registered: "Platform registered."
            case .updated: "Platform updated."
            case .enabled: "Platform enabled."
            case .disabled: "Platform disabled. It accepts no launches."
            case .deleted: "Platform deleted."
            case .deletedUnbound:
                "Platform deleted. Its courses are no longer bound to the LMS, and their grades no longer go through AGS."
            }
        }
    }

    // MARK: - GET /admin/lti

    @Sendable
    func ltiPage(req: Request) async throws -> View {
        let notice = req.query[String.self, at: "ok"].flatMap(LTIAdminNotice.init(rawValue:))
        return try await renderLTIPage(req: req, flashSuccess: notice?.message)
    }

    // MARK: - POST /admin/lti/platforms

    @Sendable
    func createLTIPlatform(req: Request) async throws -> Response {
        let form = try req.content.decode(LTIPlatformForm.self)
        do {
            let valid = try form.validated()
            try await ensureUniqueLTIPlatform(valid, excluding: nil, on: req.db)
            let platform = APILTIPlatform(
                issuer: valid.issuer, clientID: valid.clientID, deploymentIDs: valid.deploymentIDs,
                authLoginURL: valid.authLoginURL, accessTokenURL: valid.accessTokenURL,
                jwksURL: valid.jwksURL, displayName: valid.displayName)
            platform.tokenAudience = valid.tokenAudience
            platform.trustUsername = valid.trustUsername
            try await platform.save(on: req.db)
            await AuditLogger.record(
                action: .ltiPlatformRegistered, targetType: .ltiPlatform, targetID: platform.id?.uuidString,
                metadata: ["issuer": valid.issuer, "client_id": valid.clientID], on: req)
            return req.redirect(to: "/admin/lti?ok=\(LTIAdminNotice.registered.rawValue)")
        } catch let error as LTIPlatformFormError {
            return try await renderLTIPage(req: req, newForm: (form, error.message))
                .encodeResponse(for: req)
        }
    }

    // MARK: - POST /admin/lti/platforms/:platformID

    @Sendable
    func updateLTIPlatform(req: Request) async throws -> Response {
        let platform = try await findLTIPlatform(req)
        let form = try req.content.decode(LTIPlatformForm.self)
        do {
            let valid = try form.validated()
            try await ensureUniqueLTIPlatform(valid, excluding: platform.id, on: req.db)
            platform.displayName = valid.displayName
            platform.issuer = valid.issuer
            platform.clientID = valid.clientID
            platform.deploymentIDs = valid.deploymentIDs
            platform.authLoginURL = valid.authLoginURL
            platform.accessTokenURL = valid.accessTokenURL
            platform.jwksURL = valid.jwksURL
            platform.tokenAudience = valid.tokenAudience
            platform.trustUsername = valid.trustUsername
            try await platform.save(on: req.db)
            await AuditLogger.record(
                action: .ltiPlatformUpdated, targetType: .ltiPlatform, targetID: platform.id?.uuidString,
                metadata: ["issuer": valid.issuer, "client_id": valid.clientID], on: req)
            return req.redirect(to: "/admin/lti?ok=\(LTIAdminNotice.updated.rawValue)")
        } catch let error as LTIPlatformFormError {
            return try await renderLTIPage(
                req: req, editing: platform.id.map { ($0, form, error.message) }
            ).encodeResponse(for: req)
        }
    }

    // MARK: - POST /admin/lti/platforms/:platformID/enabled

    @Sendable
    func setLTIPlatformEnabled(req: Request) async throws -> Response {
        struct Body: Content { var enabled: Bool }
        let platform = try await findLTIPlatform(req)
        let enabled = try req.content.decode(Body.self).enabled
        platform.enabled = enabled
        try await platform.save(on: req.db)
        await AuditLogger.record(
            action: .ltiPlatformUpdated, targetType: .ltiPlatform, targetID: platform.id?.uuidString,
            metadata: ["issuer": platform.issuer, "enabled": String(enabled)], on: req)
        let notice: LTIAdminNotice = enabled ? .enabled : .disabled
        return req.redirect(to: "/admin/lti?ok=\(notice.rawValue)")
    }

    // MARK: - POST /admin/lti/platforms/:platformID/delete

    /// Deletes the platform and unbinds its courses in one transaction. The
    /// identity, login-state and deep-link rows go with the platform through
    /// their foreign keys; `courses.lti_platform_id` has none, so a bound
    /// course would otherwise keep a dangling platform ID that sends grades
    /// nowhere and blocks a new binding (#1647).
    @Sendable
    func deleteLTIPlatform(req: Request) async throws -> Response {
        let platform = try await findLTIPlatform(req)
        let platformID = try platform.requireID()
        let issuer = platform.issuer
        let unbound = try await req.db.transaction { db in
            let courses = try await APICourse.query(on: db).filter(\.$ltiPlatformID == platformID).all()
            for course in courses {
                course.ltiPlatformID = nil
                course.ltiContextID = nil
                course.ltiLineItemsURL = nil
                course.ltiMembershipsURL = nil
                course.ltiGradesEnabled = nil
                try await course.save(on: db)
            }
            try await platform.delete(on: db)
            return courses.count
        }
        await AuditLogger.record(
            action: .ltiPlatformDeleted, targetType: .ltiPlatform, targetID: platformID.uuidString,
            metadata: ["issuer": issuer, "courses_unbound": String(unbound)], on: req)
        let notice: LTIAdminNotice = unbound > 0 ? .deletedUnbound : .deleted
        return req.redirect(to: "/admin/lti?ok=\(notice.rawValue)")
    }

    // MARK: - Helpers

    private func findLTIPlatform(_ req: Request) async throws -> APILTIPlatform {
        guard
            let raw = req.parameters.get("platformID"),
            let id = UUID(uuidString: raw),
            let platform = try await APILTIPlatform.find(id, on: req.db)
        else { throw Abort(.notFound) }
        return platform
    }

    /// Checks the `(issuer, client_id)` uniqueness the table enforces, so the
    /// admin sees a sentence instead of a constraint violation.
    private func ensureUniqueLTIPlatform(
        _ form: LTIPlatformForm.Validated, excluding id: UUID?, on db: Database
    ) async throws {
        var query = APILTIPlatform.query(on: db)
            .filter(\.$issuer == form.issuer)
            .filter(\.$clientID == form.clientID)
        if let id { query = query.filter(\.$id != id) }
        if try await query.first() != nil { throw LTIPlatformFormError.duplicate }
    }

    private func renderLTIPage(
        req: Request,
        flashSuccess: String? = nil,
        newForm: (form: LTIPlatformForm, error: String)? = nil,
        editing: (id: UUID, form: LTIPlatformForm, error: String)? = nil
    ) async throws -> View {
        let platforms = try await APILTIPlatform.query(on: req.db).sort(\.$displayName).all()
        let rows = platforms.compactMap { platform -> AdminLTIPlatformRow? in
            guard let id = platform.id else { return nil }
            let isEditing = editing?.id == id
            return AdminLTIPlatformRow(
                id: id.uuidString,
                displayName: platform.displayName,
                issuer: platform.issuer,
                clientID: platform.clientID,
                deploymentCount: platform.deploymentIDs.count,
                enabled: platform.enabled,
                editOpen: isEditing,
                fields: LTIPlatformFieldsContext(
                    idPrefix: "lti-\(id.uuidString)",
                    form: isEditing
                        ? (editing?.form ?? LTIPlatformForm(platform: platform))
                        : LTIPlatformForm(platform: platform),
                    error: isEditing ? editing?.error : nil))
        }
        let endpoints = LTIToolEndpoints(publicBaseURL: req.application.appConfig.security.publicBaseURL)
        let ctx = AdminLTIContext(
            currentUser: req.currentUserContext,
            activeAdminTab: "lti",
            baseURLConfigured: endpoints.isAbsolute,
            loginURL: endpoints.loginURL,
            launchURL: endpoints.launchURL,
            jwksURL: endpoints.jwksURL,
            platforms: rows,
            enabledPlatformCount: rows.filter(\.enabled).count,
            newPlatformOpen: newForm != nil || rows.isEmpty,
            newFields: LTIPlatformFieldsContext(
                idPrefix: "lti-new", form: newForm?.form ?? .empty, error: newForm?.error),
            flashSuccess: flashSuccess,
            flashError: nil)
        return try await req.view.render("admin-lti", ctx)
    }
}
