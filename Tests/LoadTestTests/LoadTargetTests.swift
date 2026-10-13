import Core
import Foundation
import Testing

@testable import chickadee_loadtest

@Suite struct LoadTargetTests {
    @Test(arguments: [
        "http://localhost:8080",
        "http://127.0.0.1:8080/",
        "http://[::1]:8080",
        "https://LOCALHOST",
    ])
    func loopbackHostIsAccepted(url: String) throws {
        _ = try LoadTarget(baseURL: url, allowRemote: false)
    }

    /// A simulated runner can claim a real job, so a remote host needs an
    /// explicit opt-in.
    @Test func remoteHostIsRefusedByDefault() {
        #expect(throws: LoadTargetError.remoteHostRefused("chickadee.example.edu")) {
            try LoadTarget(baseURL: "https://chickadee.example.edu", allowRemote: false)
        }
    }

    @Test func remoteHostIsAcceptedWithTheOptIn() throws {
        let target = try LoadTarget(baseURL: "https://staging.example.edu", allowRemote: true)
        #expect(target.url(forPath: "/api/v1/worker/request") == "https://staging.example.edu/api/v1/worker/request")
    }

    @Test(arguments: ["", "localhost:8080", "ftp://localhost", "not a url"])
    func malformedURLIsRefused(url: String) {
        #expect(throws: LoadTargetError.invalidURL(url)) {
            try LoadTarget(baseURL: url, allowRemote: true)
        }
    }

    @Test func trailingSlashesDoNotDoubleTheSeparator() throws {
        let target = try LoadTarget(baseURL: "http://localhost:8080//", allowRemote: false)
        #expect(target.url(forPath: "/api/v1/submissions/x") == "http://localhost:8080/api/v1/submissions/x")
    }
}
