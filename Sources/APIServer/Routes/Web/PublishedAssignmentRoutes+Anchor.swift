// APIServer/Routes/Web/PublishedAssignmentRoutes+Anchor.swift
//
//   PUT /instructor/:assignmentID/suite-anchor   {"script": "...", "anchor": "name" | null}
//
// Pins a hand-written test to the notebook cell that defines `anchor`, or
// clears the pin (notebook views NB7, "Pin to a cell"). The pin is rule 1 of
// the anchoring (docs/notebook-guide.md, "Anchors"). A generated test is
// anchored by its check or family, so it cannot be pinned. Grading never
// reads a pin, so this does not close, re-validate or retest anything.

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
            throw WebAssignmentError.invalidParameter(
                name: "request body", reason: "Invalid anchor payload: \(error.localizedDescription)")
        }
        let anchor = body.anchor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = (anchor?.isEmpty == false) ? anchor : nil

        try await mutateManifest(setup: setup, on: req.db) { props in
            guard let index = props.testSuites.firstIndex(where: { $0.script == body.script }) else {
                throw WebAssignmentError.invalidParameter(
                    name: "script", reason: "The suite has no test named '\(body.script)'.")
            }
            guard !props.testSuites[index].isGenerated else {
                throw WebAssignmentError.invalidParameter(
                    name: "script",
                    reason: "'\(body.script)' is generated, so its check or family names its cell.")
            }
            props.testSuites[index].anchor = effective
        }
        return try await SuiteAnchorPayload(script: body.script, anchor: effective).encodeResponse(for: req)
    }
}
