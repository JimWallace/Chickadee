// Guards the MCP student-data least-privilege wall for the acting-user
// personalization-seed bookkeeping.
//
// The MCP personalization tools (`update_global_inputs`,
// `update_section_variables`, `preview_personalization`) ensure the acting
// account's own per-assignment seed as a side effect of an edit/preview. That
// SELECT/INSERT hits `assignment_personalization_seeds`, a table the
// `chickadee_mcp` least-privilege role is deliberately denied
// (deploy/sql/mcp-least-privilege-role.sql). So the seed bookkeeping must run on
// the MAIN (owner) pool — `ToolContext.mainDB` / the `seedDB` parameter — never
// the `.mcp` content pool. These tests assert that routing, so a regression back
// to the content pool (which previously needed a stopgap GRANT in prod) fails CI.

import Core
import Fluent
import FluentSQLiteDriver
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct MCPSeedMainPoolTests {

    private let manifestWithRoom = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    /// A second, unmigrated in-memory database with NO
    /// `assignment_personalization_seeds` table — stands in for the
    /// least-privilege `.mcp` pool, where that table is unreachable. Caller owns
    /// shutdown.
    private func makeSeedlessPool() async throws -> Application {
        try await makeTestingApplication { app in
            try configureDatabase(app, settings: .sqliteInMemory())
        }
    }

    // MARK: - GlobalInputsService (update_global_inputs)

    /// `GlobalInputsService.apply` must send the acting-user seed bookkeeping to
    /// `seedDB`, never the content `db`. We pass a `seedDB` that lacks the seed
    /// table (modelling the denied `.mcp` grant): the seed step fails there, and
    /// — critically — the content pool is never used for the seed, so no row
    /// leaks onto it. (Had `apply` used the content `db`, which HAS the table,
    /// the seed step would not fail here and a row would land on the content
    /// pool — exactly the wall breach this guards.)
    @Test func globalInputsApplyRoutesSeedWriteToSeedDBNotContentPool() async throws {
        let contentApp = try await makeTestApp()
        let seedlessApp = try await makeSeedlessPool()
        do {
            try await withApp(contentApp) { app in
                let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
                let courseID = try course.requireID()
                let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
                try await makeTestSetup(
                    on: app, id: "setup_seed", courseID: courseID, manifest: manifestWithRoom)
                let assignment = try await makeTestAssignment(
                    on: app, testSetupID: "setup_seed", courseID: courseID, title: "Lab")
                let setup = try #require(try await APITestSetup.find("setup_seed", on: app.db))

                await #expect(throws: (any Error).self) {
                    _ = try await GlobalInputsService.apply(
                        setup: setup,
                        assignment: assignment,
                        actingUserID: try tester.requireID(),
                        inputs: .init(
                            variables: [],
                            expressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]),
                        testSetupsDirectory: app.testSetupsDirectory,
                        pools: .init(content: app.db, seed: seedlessApp.db))
                }

                let leaked = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
                #expect(leaked == 0, "seed bookkeeping must not touch the content (.mcp) pool")
            }
            try await seedlessApp.asyncShutdown()
        } catch {
            try? await seedlessApp.asyncShutdown()
            throw error
        }
    }

    // MARK: - SectionInputsService (update_section_variables)

    /// Same guarantee for the section-scoped path: the seed bookkeeping goes to
    /// `seedDB`, not the content `db`.
    @Test func sectionInputsApplyRoutesSeedWriteToSeedDBNotContentPool() async throws {
        let contentApp = try await makeTestApp()
        let seedlessApp = try await makeSeedlessPool()
        do {
            try await withApp(contentApp) { app in
                let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
                let courseID = try course.requireID()
                let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
                try await makeTestSetup(
                    on: app, id: "setup_seed", courseID: courseID, manifest: manifestWithRoom)
                let assignment = try await makeTestAssignment(
                    on: app, testSetupID: "setup_seed", courseID: courseID, title: "Lab")
                let setup = try #require(try await APITestSetup.find("setup_seed", on: app.db))

                await #expect(throws: (any Error).self) {
                    try await SectionInputsService.apply(
                        setup: setup,
                        sectionID: "sec1",
                        inputs: .init(
                            variables: [],
                            expressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]),
                        seed: .init(
                            actingUserID: try tester.requireID(),
                            assignmentID: try assignment.requireID(),
                            testSetupID: assignment.testSetupID,
                            testSetupsDirectory: app.testSetupsDirectory),
                        on: app.db,
                        seedDB: seedlessApp.db)
                }

                let leaked = try await APIAssignmentPersonalizationSeed.query(on: app.db).count()
                #expect(leaked == 0, "seed bookkeeping must not touch the content (.mcp) pool")
            }
            try await seedlessApp.asyncShutdown()
        } catch {
            try? await seedlessApp.asyncShutdown()
            throw error
        }
    }

    // MARK: - ToolContext.mainDB vs the least-privilege .mcp pool

    /// With a dedicated MCP pool configured, `ToolContext.mainDB` is the owner
    /// pool (the seed table is reachable) while `ToolContext.db` is the
    /// least-privilege `.mcp` pool (the seed table is NOT). This is the exact
    /// `ensureSeed(on: context.mainDB)` call `preview_personalization` makes: it
    /// succeeds precisely because it does NOT require any grant on the mcp role.
    @Test func mainDBReachesSeedTableButLeastPrivilegeMCPPoolDoesNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            // Model production: a dedicated MCP pool that, like the chickadee_mcp
            // role, cannot see assignment_personalization_seeds. A fresh,
            // unmigrated in-memory DB has no such table at all.
            app.databases.use(.sqlite(SQLiteConfiguration(storage: .memory)), as: .mcp)
            app.usesDedicatedMCPDatabase = true

            let context = ToolContext(
                request: Request(application: app, on: app.eventLoopGroup.any()),
                subject: "tester",
                grantedScopes: [.write])

            // Owner-pool content the seed's FKs need.
            let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
            let courseID = try course.requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestSetup(
                on: app, id: "setup_seed", courseID: courseID, manifest: manifestWithRoom)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_seed", courseID: courseID, title: "Lab")

            // The seed bookkeeping runs on mainDB (owner pool) and succeeds even
            // though the MCP pool lacks the table.
            let seed = try await AssignmentSeedStore.ensureSeed(
                userID: try tester.requireID(),
                assignmentID: try assignment.requireID(),
                on: context.mainDB)
            #expect(seed.count == 2 * AssignmentSeedStore.seedByteCount)

            let mainRows = try await APIAssignmentPersonalizationSeed.query(on: context.mainDB).count()
            #expect(mainRows == 1)

            // The least-privilege MCP pool genuinely cannot touch that table:
            // routing the seed write there would have failed (prod: "permission
            // denied"; here: "no such table"). This is why the write must NOT use
            // `context.db`, and why the chickadee_mcp role needs no grant on it.
            await #expect(throws: (any Error).self) {
                _ = try await APIAssignmentPersonalizationSeed.query(on: context.db).count()
            }
        }
    }
}
