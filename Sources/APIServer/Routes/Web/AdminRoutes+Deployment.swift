// APIServer/Routes/Web/AdminRoutes+Deployment.swift
//
// Admin "Deployment" tab (docs/release-gate.md): what runs, what waits for
// approval, the deploy mode, pause, and the deploy history.
//
//   GET  /admin/deployment          → AdminDeploymentPage
//   POST /admin/deployment/approve  → ask the daemon to deploy the held release
//                                     (the admin types its version to confirm)
//   POST /admin/deployment/mode     → ask the daemon to change the mode
//   POST /admin/deployment/pause    → ask the daemon to pause
//   POST /admin/deployment/resume   → ask the daemon to resume
//
// The page asks; the daemon decides. Each POST writes one request file into
// the requests folder, the one place the app may write in the deploy state
// folder, and one audit-log entry. The daemon validates the request on its
// next poll and records it, accepted or refused, in its history. There is no
// rollback here: rollback stays a host action, and the page shows the host
// command for reference.

import Core
import Elementary
import Foundation
import Vapor

extension AdminRoutes {
    /// Post-redirect notices, as keys so a query string cannot put arbitrary
    /// text on the page.
    enum DeploymentNotice: String {
        case approved, modeRequested, paused, resumed, alreadyWaiting, modeUnchanged
        case versionMismatch, nothingHeld, unknownMode, requestsFolderMissing, writeFailed

        var message: String {
            switch self {
            case .approved: "Approved; it deploys on the daemon’s next poll."
            case .modeRequested: "Mode change sent; it takes effect on the daemon’s next poll."
            case .paused: "Pause sent; it takes effect on the daemon’s next poll."
            case .resumed: "Resume sent; it takes effect on the daemon’s next poll."
            case .alreadyWaiting: "Already sent; it takes effect on the daemon’s next poll."
            case .modeUnchanged: "That is already the deploy mode; nothing was sent."
            case .versionMismatch:
                "Nothing was sent: the version you typed is neither the held release nor the offered pre-release."
            case .nothingHeld: "Nothing was sent: no release or pre-release is waiting for approval."
            case .unknownMode: "Nothing was sent: that is not a deploy mode."
            case .requestsFolderMissing:
                "Nothing was sent: the deploy requests folder is not mounted in this container."
            case .writeFailed: "Nothing was sent: the request could not be written."
            }
        }

        var isError: Bool {
            switch self {
            case .approved, .modeRequested, .paused, .resumed, .alreadyWaiting, .modeUnchanged: false
            case .versionMismatch, .nothingHeld, .unknownMode, .requestsFolderMissing, .writeFailed: true
            }
        }
    }

    private var deploymentPath: String { "/admin/deployment" }

    // MARK: - GET /admin/deployment

    @Sendable
    func deploymentPage(req: Request) async throws -> HTMLResponse<AdminDeploymentPage> {
        let notice = req.query[String.self, at: "notice"].flatMap(DeploymentNotice.init(rawValue:))
        let flash =
            notice.map { $0.isError ? FlashMessages(error: $0.message) : FlashMessages(success: $0.message) }
            ?? FlashMessages()
        let view = AdminDeploymentView.make(folder: DeployStateFolder(directory: req.application.deployStateDirectory))
        return HTMLResponse {
            AdminDeploymentPage(page: PageRequestContext(request: req), flash: flash, view: view)
        }
    }

    // MARK: - POST /admin/deployment/approve

    @Sendable
    func approveDeployment(req: Request) async throws -> Response {
        struct Form: Content { var version: String? }
        let typed = ((try? await req.decodeContent(Form.self))?.version ?? "").trimmingCharacters(in: .whitespaces)
        let folder = DeployStateFolder(directory: req.application.deployStateDirectory)
        let status = folder.status()
        // The held release, or the pre-release the daemon offers on the Coming
        // next card. The daemon checks the same again before it acts.
        let approvable = [status?.heldVersion, status?.prereleaseVersion].compactMap(\.self).filter { !$0.isEmpty }
        guard !approvable.isEmpty else {
            return redirect(req, .nothingHeld)
        }
        guard approvable.contains(typed), DeployStateFolder.isReleaseTag(typed) else {
            return redirect(req, .versionMismatch)
        }
        return await send(
            .approve(version: typed), notice: .approved, action: .deployApproveRequested,
            metadata: ["version": typed], folder: folder, req: req)
    }

    // MARK: - POST /admin/deployment/mode

    @Sendable
    func setDeploymentMode(req: Request) async throws -> Response {
        struct Form: Content { var mode: String? }
        guard let raw = (try? await req.decodeContent(Form.self))?.mode, let mode = DeployMode(rawValue: raw) else {
            return redirect(req, .unknownMode)
        }
        let folder = DeployStateFolder(directory: req.application.deployStateDirectory)
        return await send(
            .mode(mode), notice: .modeRequested, action: .deployModeRequested,
            metadata: ["mode": mode.rawValue], folder: folder, req: req)
    }

    // MARK: - POST /admin/deployment/pause, /resume

    @Sendable
    func pauseDeployment(req: Request) async throws -> Response {
        let folder = DeployStateFolder(directory: req.application.deployStateDirectory)
        return await send(
            .pause, notice: .paused, action: .deployPauseRequested, metadata: [:], folder: folder,
            req: req)
    }

    @Sendable
    func resumeDeployment(req: Request) async throws -> Response {
        let folder = DeployStateFolder(directory: req.application.deployStateDirectory)
        return await send(
            .resume, notice: .resumed, action: .deployResumeRequested, metadata: [:],
            folder: folder, req: req)
    }

    // MARK: - Helpers

    /// Writes one request file and one audit entry, then returns to the page.
    /// A request that cannot be written is logged and audited nowhere: nothing
    /// was asked of the daemon.
    private func send(
        _ request: DeployRequest, notice: DeploymentNotice, action: AuditAction, metadata: [String: String],
        folder: DeployStateFolder, req: Request
    ) async -> Response {
        let user = req.auth.get(APIUser.self)?.username ?? "unknown"
        // A request that repeats what already waits, or a mode change to the
        // mode in force, would only repeat itself in the history.
        switch request.redundancy(waiting: folder.waitingRequests(), modeInForce: folder.modeInForce()) {
        case .alreadyWaiting: return redirect(req, .alreadyWaiting)
        case .alreadyInForce: return redirect(req, .modeUnchanged)
        case nil: break
        }
        do {
            let file = try folder.write(request, user: user)
            await AuditLogger.record(
                action: action, targetType: .deployment, targetID: file, metadata: metadata, on: req)
            return redirect(req, notice)
        } catch {
            req.logger.error(
                "deploy request not written",
                metadata: ["error": "\(error)", "folder": "\(folder.requestsFolder.path)"])
            return redirect(req, error == .requestsFolderMissing ? .requestsFolderMissing : .writeFailed)
        }
    }

    private func redirect(_ req: Request, _ notice: DeploymentNotice) -> Response {
        req.redirect(to: "\(deploymentPath)?notice=\(notice.rawValue)")
    }
}
