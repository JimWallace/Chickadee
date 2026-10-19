// Pins the GRANT parser that MCPLeastPrivilegeGrantSyncTests and
// MCPAuthoringGrantCoverageTests share, so a statement shape it misreads
// cannot make either suite pass without a real grant.

import Testing

@Suite struct MCPRoleGrantsTests {
    @Test func parserReadsEachStatementShape() throws {
        let sql = """
            GRANT USAGE ON SCHEMA public TO chickadee_mcp;
            GRANT SELECT, INSERT ON
                alpha, beta
                TO chickadee_mcp;
            grant update on gamma to chickadee_mcp;
            GRANT SELECT ON epsilon TO someone_else;
            -- GRANT DELETE ON zeta TO chickadee_mcp;
            """
        let grants = try MCPRoleGrants.privilegesByTable(in: sql)
        #expect(grants == ["alpha": ["SELECT", "INSERT"], "beta": ["SELECT", "INSERT"], "gamma": ["UPDATE"]])
    }

    /// A column grant lets the role read only those columns, so it is not a
    /// table-level SELECT: a query that reads any other column is refused.
    @Test func columnGrantIsNotATableGrant() throws {
        let sql = "GRANT SELECT (id, kind), UPDATE ON delta TO chickadee_mcp;"
        let grants = try MCPRoleGrants.privilegesByTable(in: sql)
        #expect(grants == ["delta": ["SELECT (id,kind)", "UPDATE"]])
        #expect(grants["delta"]?.contains("SELECT") == false)
    }

    @Test func theRealFileParses() throws {
        let grants = try MCPRoleGrants.privilegesByTable()
        #expect(grants.count > 10, "sanity: the grants were found")
        #expect(grants["course_content_items"] == ["SELECT", "INSERT", "UPDATE", "DELETE"])
    }
}
