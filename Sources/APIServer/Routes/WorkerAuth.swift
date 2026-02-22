import Vapor

/// Validates `X-Worker-Secret` against the server's effective worker secret.
/// This allows non-browser worker processes to authenticate without a session cookie.
@Sendable
func requireWorkerSecret(_ req: Request) async throws {
    let provided = req.headers.first(name: "X-Worker-Secret")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let expected = (await req.application.workerSecretStore.effectiveSecret() ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !expected.isEmpty else {
        throw Abort(.unauthorized, reason: "Worker auth is not configured.")
    }
    guard provided == expected else {
        throw Abort(.unauthorized, reason: "Invalid worker secret.")
    }
}
