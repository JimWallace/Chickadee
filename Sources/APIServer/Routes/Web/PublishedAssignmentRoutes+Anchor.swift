// APIServer/Routes/Web/PublishedAssignmentRoutes+Anchor.swift
//
//   PUT /instructor/:assignmentID/suite-anchor   {"script": "...", "anchor": "name" | null}
//
// Pins a hand-written test to the notebook cell that defines `anchor`, or
// clears the pin (notebook views NB7, "Pin to a cell"). The pin is rule 1 of
// the anchoring (docs/notebook-guide.md, "Anchors"). A generated test is
// anchored by its check or family, so it cannot be pinned. Grading never
// reads a pin, so this does not close, re-validate or retest anything.
// `SuiteAnchorPinning` holds the rule; MCP `update_suite` shares it.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
    struct SuiteAnchorPayload: Content {
        var script: String
        var anchor: String?
    }

    @Sendable
    func putSuiteAnchor(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req, atLeast: .ta)
        let body: SuiteAnchorPayload
        do { body = try await req.decodeContent(SuiteAnchorPayload.self) } catch {
            throw AppError.invalidParameter(
                name: "request body", reason: "Invalid anchor payload: \(error.localizedDescription)")
        }
        let effective = SuiteAnchorPinning.normalized(body.anchor)
        do {
            try await SuiteAnchorPinning.apply(
                [SuiteAnchorPinning.Pin(script: body.script, anchor: effective)], setup: setup, on: req.db)
        } catch let error as SuiteAnchorPinning.PinError {
            throw AppError.invalidParameter(name: "script", reason: error.message)
        }
        return try await SuiteAnchorPayload(script: body.script, anchor: effective).encodeResponse(for: req)
    }
}
