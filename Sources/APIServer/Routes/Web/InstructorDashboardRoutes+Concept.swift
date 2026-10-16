// APIServer/Routes/Web/InstructorDashboardRoutes+Concept.swift
//
// The per-assignment lab concept (Student Options): full marks on the
// assignment earn the concept's wardrobe ring (docs/student-wardrobe.md,
// "Concept rings").
//
//   POST /instructor/:assignmentID/concept

import Core
import Fluent
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - POST /instructor/:assignmentID/concept

    /// Saves the concept. A dedicated lightweight endpoint, like the other
    /// Student Options: the main Save closes and re-validates, which a
    /// cosmetic setting must not do. No manifest change, no regrade, no
    /// grade change. An empty value clears the concept; an unknown one is
    /// refused with an error banner.
    @Sendable
    func saveConceptSetting(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForWrite(req, atLeast: .instructor)
        struct ConceptBody: Content {
            var concept: String?
        }
        let raw = (try? await req.decodeContent(ConceptBody.self))?.concept ?? ""
        if raw.isEmpty {
            assignment.concept = nil
        } else if let concept = AssignmentConcept(rawValue: raw) {
            assignment.concept = concept
        } else {
            return req.redirect(to: "/instructor/\(assignment.publicID)/edit?error=Unknown+wardrobe+ring")
        }
        try await assignment.save(on: req.db)
        return req.redirect(to: "/instructor/\(assignment.publicID)/edit?notice=Wardrobe+ring+saved")
    }
}
