import Fluent
import Testing

@testable import chickadee_server

@Suite struct CurrentUserContextTests {

    @Test func trimsProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "  jsmith@example.edu  ",
            preferredName: "  Jane  ",
            displayName: "  Jane Smith  "
        )

        let ctx = CurrentUserContext(user: user)
        #expect(ctx.username == "jsmith")
        #expect(ctx.preferredName == "Jane")
        #expect(ctx.displayName == "Jane Smith")
        #expect(ctx.email == "jsmith@example.edu")
    }

    @Test func dropsBlankProfileFields() {
        let user = APIUser(
            username: "jsmith",
            passwordHash: "",
            role: "student",
            email: "   ",
            preferredName: " ",
            displayName: "\n"
        )

        let ctx = CurrentUserContext(user: user)
        #expect(ctx.preferredName == nil)
        #expect(ctx.displayName == nil)
        #expect(ctx.email == nil)
    }
}
