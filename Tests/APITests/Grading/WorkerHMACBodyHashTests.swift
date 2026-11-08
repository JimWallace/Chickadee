// Tests/APITests/Grading/WorkerHMACBodyHashTests.swift
//
// The worker signature covers the `X-Worker-Body-SHA256` header, not the
// body. `WorkerHMACAuthMiddleware` must compare the header with the bytes it
// received, or an attacker on the path keeps a runner's signed headers and
// swaps the body for a forged result (#2896). It must also record the replay
// nonce only for a genuinely signed request, and cap the worker id.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
struct WorkerHMACBodyHashTests {
    private let sharedSecret = "test-shared-secret"
    private let path = "/internal/worker/ping"

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.routes.defaultMaxBodySize = "10mb"
        do {
            try await configureEmptyPostgresTestSchema(app)
            app.migrations.add(CreateWorkerNonces())
            try await app.autoMigrate()
        } catch {
            try? await app.tearDownTestApp()
            throw error
        }
        app.workerSecretStore = WorkerSecretStore(initialOverride: sharedSecret)
        app.grouped(WorkerHMACAuthMiddleware()).post("internal", "worker", "ping") { _ in
            HTTPStatus.ok
        }
        return app
    }

    private func send(
        _ app: Application, headers: HTTPHeaders, body: ByteBuffer
    ) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req async in
                req.headers = headers
                req.body = body
            },
            afterResponse: { res async in status = res.status })
        return status
    }

    @Test func theSignedBodyIsAccepted() async throws {
        let body = ByteBuffer(string: #"{"score":0.1}"#)
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: sharedSecret)
        try await withApp(try await makeApp()) { app in
            let status = try await send(app, headers: headers, body: body)
            #expect(status == .ok)
        }
    }

    @Test func aSwappedBodyIsRefused() async throws {
        let signed = ByteBuffer(string: #"{"score":0.1}"#)
        let forged = ByteBuffer(string: #"{"score":1.0}"#)
        let headers = workerHMACHeaders(method: .POST, path: path, body: signed, workerSecret: sharedSecret)
        try await withApp(try await makeApp()) { app in
            let status = try await send(app, headers: headers, body: forged)
            #expect(status == .unauthorized)
        }
    }

    @Test func aBadSignatureStoresNoNonce() async throws {
        let body = ByteBuffer(string: "{}")
        let headers = workerHMACHeaders(method: .POST, path: path, body: body, workerSecret: "wrong-secret")
        try await withApp(try await makeApp()) { app in
            let status = try await send(app, headers: headers, body: body)
            #expect(status == .unauthorized)
            let rows = try await WorkerNonce.query(on: app.db).count()
            #expect(rows == 0)
        }
    }

    @Test func anOverlongWorkerIDIsRefused() async throws {
        let body = ByteBuffer(string: "{}")
        let longID = String(repeating: "w", count: WorkerHMACAuthMiddleware.maxWorkerIDBytes + 1)
        let headers = workerHMACHeaders(
            method: .POST, path: path, body: body, workerSecret: sharedSecret, workerID: longID)
        try await withApp(try await makeApp()) { app in
            let status = try await send(app, headers: headers, body: body)
            #expect(status == .unauthorized)
            let rows = try await WorkerNonce.query(on: app.db).count()
            #expect(rows == 0)
        }
    }
}
