// APIServer/Routes/Web/SuitePayloadDTOs.swift
//
// Suite editor request/response DTOs used by both the published-assignment
// and draft-assignment suite endpoints.  Lifted out of the original
// `extension AssignmentRoutes` (nested types) in v0.4.177 so the Draft
// and Published collections can share them after the route-collection
// split.  Pure DTOs — no behaviour, no dependency on the route struct.

import Core
import Vapor

/// One row in the unified suite list, in either direction (GET response
/// or PUT request body).  Array order is authoritative for UI order.
struct SuiteItemDTO: Content {
    /// "script", "family", or "check".
    var kind: String
    /// Present when kind == "script".
    var script: ScriptDTO?
    /// Present when kind == "family".
    var family: PatternFamily?
    /// Present when kind == "check".  Carried so the editor can render
    /// label/tier/points read-only without a separate `/checks` GET.
    var check: NotebookCheck?
    /// Present when kind == "family".  Family-level deps live on the
    /// family spec too, but we echo them here at the row level for
    /// editor-UI convenience.
    var dependsOn: [String]?
    /// Id into `SuitePayload.sections` (all kinds).  Nil = ungrouped.
    var sectionID: String?
}

struct ScriptDTO: Content {
    var script: String  // filename
    var tier: TestTier
    var points: Int
    var displayName: String?
    var dependsOn: [String]  // may contain "family:<id>" tokens
}

/// Name + opaque id of a single section.  Order of `SuitePayload.sections`
/// is authoritative for display order in the editor and the student view.
struct TestSuiteSectionDTO: Content {
    var id: String
    var name: String
}

struct SuitePayload: Content {
    var items: [SuiteItemDTO]
    /// Ordered list of sections.  Clients predating v0.4.96 may omit
    /// this field; it decodes to `[]` in that case.  Always populated
    /// on GET responses.
    var sections: [TestSuiteSectionDTO]

    init(items: [SuiteItemDTO], sections: [TestSuiteSectionDTO] = []) {
        self.items = items
        self.sections = sections
    }

    enum CodingKeys: String, CodingKey { case items, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SuiteItemDTO].self, forKey: .items) ?? []
        sections = try c.decodeIfPresent([TestSuiteSectionDTO].self, forKey: .sections) ?? []
    }
}
