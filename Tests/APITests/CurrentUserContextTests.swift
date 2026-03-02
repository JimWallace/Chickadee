import XCTest
@testable import chickadee_server

final class CurrentUserContextTests: XCTestCase {

    func testCurrentUserContextTrimsProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "  jsmith@example.edu  ",
            preferredName: "  Jane  ",
            displayName: "  Jane Smith  "
        )

        let ctx = CurrentUserContext(user: user)
        XCTAssertEqual(ctx.username, "jsmith")
        XCTAssertEqual(ctx.preferredName, "Jane")
        XCTAssertEqual(ctx.displayName, "Jane Smith")
        XCTAssertEqual(ctx.email, "jsmith@example.edu")
    }

    func testCurrentUserContextDropsBlankProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "   ",
            preferredName: " ",
            displayName: "\n"
        )

        let ctx = CurrentUserContext(user: user)
        XCTAssertNil(ctx.preferredName)
        XCTAssertNil(ctx.displayName)
        XCTAssertNil(ctx.email)
    }
}
