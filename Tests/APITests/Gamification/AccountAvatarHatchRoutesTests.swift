// Tests/APITests/Gamification/AccountAvatarHatchRoutesTests.swift
//
// "Hatch a new bird" on the account page (Core/AvatarHatch.swift):
//   POST /account/avatar/hatch    — a bird of another species, 3 per term
//   POST /account/avatar/restore  — back to the bird before the last hatch
// and the states the bird card shows for them.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class AccountAvatarHatchRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-acct-hatch")
    }

    private func user(_ username: String) async throws -> APIUser {
        try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
    }

    private func storedSpec(_ username: String) async throws -> AvatarSpec {
        try #require(try await user(username).avatarSpecJSON.flatMap(AvatarStore.decode))
    }

    private func previousSpec(_ username: String) async throws -> AvatarSpec? {
        try await user(username).avatarPreviousSpecJSON.flatMap(AvatarStore.decode)
    }

    /// Logs in a fresh student and draws their bird.
    private func student(_ username: String) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        _ = try await getHTML("/account", cookie: cookie, on: app)
        return cookie
    }

    /// Posts to `path` with a CSRF token and returns the redirect target.
    private func post(_ path: String, cookie: String, csrf: Bool = true) async throws -> (HTTPStatus, String?) {
        let (token, newCookie) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .internalServerError
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: newCookie)
                try req.content.encode(csrf ? ["_csrf": token] : [:], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    private func currentTermKey() throws -> String {
        AvatarHatch.termKey(for: try #require(AcademicTerm.current()))
    }

    // MARK: - Hatch

    @Test func aHatchGivesAnotherSpeciesAndANewHandleAndKeepsBackdropAndRing() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_one")
            let course = try await makeTestCourse(on: app, code: "HATCH101")
            let student = try await user("hatch_one")
            try await APICourseEnrollment(
                userID: try student.requireID(), courseID: try course.requireID(), role: .student
            ).save(on: app.db)
            student.avatarHandle = "Quiet Cedar"
            try await student.save(on: app.db)
            let before = try await storedSpec("hatch_one")

            let (_, location) = try await post("/account/avatar/hatch", cookie: cookie)
            #expect(location == "/account?avatar=hatched#bird")

            let after = try await storedSpec("hatch_one")
            #expect(after.species != before.species)
            #expect(after.backdrop == before.backdrop)
            #expect(after.border == before.border)
            #expect(try await previousSpec("hatch_one") == before)
            // A new name with the new bird, in every course at once.
            let hatched = try await user("hatch_one")
            let handle = try #require(hatched.avatarHandle)
            #expect(handle != "Quiet Cedar")
            #expect(AvatarHandle.isWellFormed(handle))
            #expect(hatched.avatarPreviousHandle == "Quiet Cedar")
            let rows = try await APIAvatarHatch.query(on: app.db)
                .filter(\.$userID == user("hatch_one").requireID()).all()
            #expect(rows.map(\.termKey) == [try currentTermKey()])
        }
    }

    @Test func theFourthHatchInATermIsRefused() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_four")
            for _ in 0..<AvatarHatch.perTerm {
                #expect(try await post("/account/avatar/hatch", cookie: cookie).1 == "/account?avatar=hatched#bird")
            }
            let spec = try await storedSpec("hatch_four")
            let previous = try await previousSpec("hatch_four")
            #expect(try await post("/account/avatar/hatch", cookie: cookie).1 == "/account?avatar=nohatch#bird")
            #expect(try await storedSpec("hatch_four") == spec)
            #expect(try await previousSpec("hatch_four") == previous)
            let html = try await getHTML("/account?avatar=nohatch", cookie: cookie, on: app)
            #expect(html.contains("No hatches are left this term."))
        }
    }

    /// Only this term's hatches count: three from an earlier term leave all
    /// three of this term.
    @Test func theCountStartsAgainInANewTerm() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_term")
            let userID = try await user("hatch_term").requireID()
            for slot in 1...AvatarHatch.perTerm {
                try await APIAvatarHatch(userID: userID, termKey: "1999-fall", slot: slot).create(on: app.db)
            }
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.contains("3 of 3 left this term"))
            #expect(try await post("/account/avatar/hatch", cookie: cookie).1 == "/account?avatar=hatched#bird")
        }
    }

    /// Two hatches at once try the same slot; the unique index refuses the
    /// second, so the limit holds in the database too.
    @Test func theDatabaseRefusesTwoHatchesInOneSlot() async throws {
        try await withApp(app) { _ in
            _ = try await student("hatch_slot")
            let userID = try await user("hatch_slot").requireID()
            try await APIAvatarHatch(userID: userID, termKey: "2026-fall", slot: 1).create(on: app.db)
            await #expect(throws: (any Error).self) {
                try await APIAvatarHatch(userID: userID, termKey: "2026-fall", slot: 1).create(on: app.db)
            }
        }
    }

    @Test func neitherPostWorksWithoutCSRF() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_csrf")
            let before = try await storedSpec("hatch_csrf")
            #expect(try await post("/account/avatar/hatch", cookie: cookie, csrf: false).0 == .forbidden)
            #expect(try await post("/account/avatar/restore", cookie: cookie, csrf: false).0 == .forbidden)
            #expect(try await storedSpec("hatch_csrf") == before)
            #expect(
                try await APIAvatarHatch.query(on: app.db).filter(\.$userID == user("hatch_csrf").requireID())
                    .count() == 0)
        }
    }

    // MARK: - Go back

    @Test func goingBackRestoresThePreviousBirdAndKeepsTheHatchUsed() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_back")
            let original = try await storedSpec("hatch_back")
            _ = try await post("/account/avatar/hatch", cookie: cookie)
            // A ring chosen after the hatch stays on the go back.
            let user = try await user("hatch_back")
            var hatched = try #require(user.avatarSpecJSON.flatMap(AvatarStore.decode))
            hatched.border = .lagoon
            user.avatarSpecJSON = AvatarStore.encode(hatched)
            try await user.save(on: app.db)

            #expect(try await post("/account/avatar/restore", cookie: cookie).1 == "/account?avatar=restored#bird")
            var expected = original
            expected.border = .lagoon
            #expect(try await storedSpec("hatch_back") == expected)
            #expect(try await previousSpec("hatch_back") == nil)
            let html = try await getHTML("/account?avatar=restored", cookie: cookie, on: app)
            #expect(html.contains("2 of 3 left this term"))
            #expect(!html.contains("Go back to my"))
        }
    }

    @Test func goingBackWithNoPreviousBirdChangesNothing() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_noback")
            let before = try await storedSpec("hatch_noback")
            #expect(try await post("/account/avatar/restore", cookie: cookie).1 == "/account#bird")
            #expect(try await storedSpec("hatch_noback") == before)
        }
    }

    // MARK: - The bird card

    @Test func theIdleCardLinksToTheConfirm() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_idle")
            let html = try await getHTML("/account", cookie: cookie, on: app)
            #expect(html.contains(#"href="/account?hatch=confirm#bird""#))
            #expect(html.contains("Hatch a new bird"))
            #expect(html.contains("3 of 3 left this term"))
            #expect(html.contains("data-avatar-hatched"))
            #expect(!html.contains("bird-card-strip"))
            #expect(html.contains(#"id="bird""#))
        }
    }

    @Test func theConfirmStripSaysWhatChangesAndPostsTheHatch() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_confirm")
            let species = try await storedSpec("hatch_confirm").species.displayName.lowercased()
            let html = try await getHTML("/account?hatch=confirm", cookie: cookie, on: app)
            #expect(html.contains("bird-card-strip"))
            #expect(html.contains("Hatch a new bird?"))
            #expect(html.contains("This uses 1 of the 3 you have left this term."))
            #expect(html.contains(#"action="/account/avatar/hatch""#))
            #expect(html.contains("Keep my \(species)"))
        }
    }

    @Test func theHatchedStripOffersTheWayBack() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_meet")
            let before = try await storedSpec("hatch_meet").species.displayName.lowercased()
            _ = try await post("/account/avatar/hatch", cookie: cookie)
            let after = try await storedSpec("hatch_meet").species.displayName.lowercased()
            let html = try await getHTML("/account?avatar=hatched", cookie: cookie, on: app)
            #expect(
                html.contains(
                    "Meet your new bird: \(AvatarHatchContext.withArticle(try await storedSpec("hatch_meet").species))."
                ))
            #expect(html.contains(after))
            #expect(html.contains("Go back to my \(before)"))
            #expect(html.contains(#"action="/account/avatar/restore""#))
            #expect(html.contains("Keep it"))
            #expect(html.contains(">New</span>"))
            // After "Keep it", the way back is a small button under the caption.
            let kept = try await getHTML("/account", cookie: cookie, on: app)
            #expect(!kept.contains("bird-card-strip"))
            #expect(kept.contains(#"class="btn-link""#))
            #expect(kept.contains("Go back to my \(before)"))
        }
    }

    @Test func withNoneLeftTheButtonIsDisabledAndTheConfirmIsNotShown() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_spent")
            let userID = try await user("hatch_spent").requireID()
            for slot in 1...AvatarHatch.perTerm {
                try await APIAvatarHatch(userID: userID, termKey: try currentTermKey(), slot: slot).create(on: app.db)
            }
            let html = try await getHTML("/account?hatch=confirm", cookie: cookie, on: app)
            #expect(!html.contains("bird-card-strip"))
            #expect(!html.contains(#"href="/account?hatch=confirm#bird""#))
            #expect(html.contains(#"<button class="btn" type="button" disabled>"#))
            let next = try #require(AcademicTerm.current()?.next).displayName
            #expect(html.contains("None left this term. 3 more when \(next) starts."))
        }
    }

    // MARK: - Export and deletion

    @Test func theExportHasTheHatchesAndThePreviousBird() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_export")
            let original = try await storedSpec("hatch_export")
            _ = try await post("/account/avatar/hatch", cookie: cookie)
            let content = try await gatherDataExportContent(for: user("hatch_export"), on: app.db)
            #expect(content.profile.previousAvatar == original)
            #expect(content.profile.avatarHatches?.map(\.term) == [try currentTermKey()])
        }
    }

    @Test func deletingTheAccountRemovesItsHatches() async throws {
        try await withApp(app) { _ in
            let cookie = try await student("hatch_delete")
            _ = try await post("/account/avatar/hatch", cookie: cookie)
            let user = try await user("hatch_delete")
            let userID = try user.requireID()
            #expect(try await APIAvatarHatch.query(on: app.db).filter(\.$userID == userID).count() == 1)
            try await user.delete(on: app.db)
            #expect(try await APIAvatarHatch.query(on: app.db).filter(\.$userID == userID).count() == 0)
        }
    }
}
