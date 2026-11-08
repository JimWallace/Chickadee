// Tests/APITests/Infrastructure/AsyncMiddlewareGroupTests.swift
//
// `AsyncMiddlewareGroup` (#2905) must behave exactly like registering its
// members one by one: the same order in and out, the same short-circuits and
// the same error handling. The production chain in `bootstrapAppMiddleware`
// relies on that, and the test app does not run that chain.

import Testing
import VaporTesting

@testable import APIServer

@Suite struct AsyncMiddlewareGroupTests {

    private struct TraceKey: StorageKey {
        typealias Value = [String]
    }

    private enum GroupTestError: Error {
        case thrown
    }

    /// Appends `step` to the request's trace.
    private static func record(_ step: String, on request: Request) {
        request.storage[TraceKey.self] = (request.storage[TraceKey.self] ?? []) + [step]
    }

    /// The request's trace so far, as one string.
    private static func trace(of request: Request) -> String {
        (request.storage[TraceKey.self] ?? []).joined(separator: " ")
    }

    /// Records its name on the way in and on the way out.
    private struct Recorder: AsyncMiddleware {
        let name: String

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            AsyncMiddlewareGroupTests.record("\(name)>", on: request)
            let response = try await next.respond(to: request)
            AsyncMiddlewareGroupTests.record("<\(name)", on: request)
            response.headers.replaceOrAdd(name: "X-Trace", value: AsyncMiddlewareGroupTests.trace(of: request))
            return response
        }
    }

    /// Answers without calling the rest of the chain.
    private struct ShortCircuit: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            AsyncMiddlewareGroupTests.record("stop", on: request)
            return Response(status: .accepted)
        }
    }

    /// Throws before the rest of the chain.
    private struct Thrower: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            AsyncMiddlewareGroupTests.record("throw", on: request)
            throw GroupTestError.thrown
        }
    }

    /// Turns an error from the rest of the chain into a 418.
    private struct Catcher: AsyncMiddleware {
        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            do {
                return try await next.respond(to: request)
            } catch GroupTestError.thrown {
                AsyncMiddlewareGroupTests.record("caught", on: request)
                let response = Response(status: .imATeapot)
                response.headers.replaceOrAdd(name: "X-Trace", value: AsyncMiddlewareGroupTests.trace(of: request))
                return response
            }
        }
    }

    /// An app whose `/run` route sits behind `middleware`, either grouped or
    /// registered one by one, and records "handler" when it runs.
    private func makeApp(_ middleware: [any AsyncMiddleware], grouped: Bool) async throws -> Application {
        let app = try await Application.make(.testing)
        if grouped {
            app.middleware.use(AsyncMiddlewareGroup(middleware))
        } else {
            for member in middleware { app.middleware.use(member) }
        }
        app.get("run") { request -> Response in
            Self.record("handler", on: request)
            return Response(status: .ok)
        }
        return app
    }

    private func trace(of middleware: [any AsyncMiddleware], grouped: Bool) async throws -> (HTTPStatus, String?) {
        var result: (HTTPStatus, String?) = (.internalServerError, nil)
        try await withApp(try await makeApp(middleware, grouped: grouped)) { app in
            try await app.asyncTest(.GET, "/run") { res async in
                result = (res.status, res.headers.first(name: "X-Trace"))
            }
        }
        return result
    }

    @Test func membersRunInOrderOnTheWayInAndInReverseOnTheWayOut() async throws {
        let members: [any AsyncMiddleware] = [Recorder(name: "a"), Recorder(name: "b"), Recorder(name: "c")]
        let grouped = try await trace(of: members, grouped: true)
        #expect(grouped.0 == .ok)
        #expect(grouped.1 == "a> b> c> handler <c <b <a")
        let separate = try await trace(of: members, grouped: false)
        #expect(grouped.0 == separate.0)
        #expect(grouped.1 == separate.1)
    }

    @Test func aMemberThatAnswersStopsTheRestButTheEarlierOnesSeeTheResponse() async throws {
        let members: [any AsyncMiddleware] = [Recorder(name: "a"), ShortCircuit(), Recorder(name: "c")]
        let grouped = try await trace(of: members, grouped: true)
        #expect(grouped.0 == .accepted)
        #expect(grouped.1 == "a> stop <a")
        let separate = try await trace(of: members, grouped: false)
        #expect(grouped.0 == separate.0)
        #expect(grouped.1 == separate.1)
    }

    @Test func anErrorReachesTheEarlierMembersAsItWouldAlone() async throws {
        let members: [any AsyncMiddleware] = [Recorder(name: "a"), Catcher(), Thrower(), Recorder(name: "d")]
        let grouped = try await trace(of: members, grouped: true)
        #expect(grouped.0 == .imATeapot)
        #expect(grouped.1 == "a> throw caught <a")
        let separate = try await trace(of: members, grouped: false)
        #expect(grouped.0 == separate.0)
        #expect(grouped.1 == separate.1)
    }

    @Test func anEmptyGroupPassesTheRequestThrough() async throws {
        let grouped = try await trace(of: [], grouped: true)
        #expect(grouped.0 == .ok)
    }

    @Test func aGroupOnARouteGroupRunsBeforeTheHandler() async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            let routes = app.grouped(AsyncMiddlewareGroup([Recorder(name: "a"), Recorder(name: "b")]))
            routes.get("run") { request -> Response in
                Self.record("handler", on: request)
                return Response(status: .ok)
            }
            try await app.asyncTest(.GET, "/run") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "X-Trace") == "a> b> handler <b <a")
            }
        }
    }
}
