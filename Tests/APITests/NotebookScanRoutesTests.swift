// Tests/APITests/NotebookScanRoutesTests.swift
//
// Integration tests for:
//   POST /instructor/scan-notebook

import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

@Suite struct NotebookScanRoutesTests {

    private func makeApp() async throws -> Application {
        let app = try await makeTestApp(prefix: "chickadee-nbscan")
        return app
    }

    // MARK: - Auth helpers

    private func loginAsInstructor(on app: Application) async throws -> String {
        return try await loginUser(
            username: "testinstructor_nbscan", password: "testpassword",
            role: "instructor", on: app)
    }

    private func loginAsStudent(on app: Application) async throws -> String {
        return try await loginUser(
            username: "teststudent_nbscan", password: "testpassword",
            role: "student", on: app)
    }

    // MARK: - Sample notebook fixtures

    private let notebookWithTwoFunctions = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": "def add(a, b):\\n    return a + b\\n\\ndef multiply(x, y):\\n    return x * y\\n"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """

    private let notebookWithNoFunctions = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": "x = 1\\ny = 2\\nprint(x + y)\\n"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """

    private let notebookWithTypeHints = """
        {
          "cells": [
            {
              "cell_type": "code",
              "metadata": {},
              "source": "def greet(name: str) -> str:\\n    return 'Hello ' + name\\n"
            }
          ],
          "metadata": {},
          "nbformat": 4,
          "nbformat_minor": 5
        }
        """

    // MARK: - POST /instructor/scan-notebook

    @Test func scanNotebookReturnsFunctionsForInstructor() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithTwoFunctions)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("\"add\""),
                        "Expected function 'add' in response, got: \(body.prefix(500))")
                    #expect(
                        body.contains("\"multiply\""),
                        "Expected function 'multiply' in response, got: \(body.prefix(500))")
                }
            )

        }
    }

    @Test func scanNotebookReturnsEmptyArrayForNoFunctions() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithNoFunctions)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(
                        res.body.string.trimmingCharacters(in: .whitespacesAndNewlines) == "[]",
                        "Expected empty array for notebook with no functions")
                }
            )

        }
    }

    @Test func scanNotebookIncludesParamNames() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithTwoFunctions)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("\"a\"") && body.contains("\"b\""),
                        "Expected param names 'a', 'b' in response, got: \(body.prefix(500))")
                    #expect(
                        body.contains("\"paramCount\""),
                        "Expected 'paramCount' field in response")
                }
            )

        }
    }

    @Test func scanNotebookIncludesTemplates() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithTwoFunctions)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("\"templates\""),
                        "Expected 'templates' array in response, got: \(body.prefix(500))")
                    #expect(
                        body.contains("\"exists\"") || body.contains("Exists"),
                        "Expected exists template in response")
                }
            )

        }
    }

    @Test func scanNotebookReturnsTypeHintFlag() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithTypeHints)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("\"hasTypeHints\":true") || body.contains("\"hasTypeHints\" : true"),
                        "Expected hasTypeHints true for typed function, got: \(body.prefix(500))")
                }
            )

        }
    }

    @Test func scanNotebookReturns403ForStudent() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsStudent(on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithTwoFunctions)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                }
            )

        }
    }

    @Test func scanNotebookReturns400ForEmptyBody() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    // No body
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                }
            )

        }
    }

    /// The scan-notebook endpoint used to drop `paramTypes`, `returnType`,
    /// `isShadowed`, and `paramHasDefault` from the DTO it emitted, so the
    /// family-editor client always saw them as `undefined` — and
    /// `coerceByType` fell back to strict `JSON.parse` on every cell,
    /// silently turning `20260422` in a `str` column into an `int`.
    /// Regression guard for v0.4.94's fix (the bug the instructor
    /// reported on their DOB-check pattern family).
    @Test func scanNotebookForwardsParamTypesReturnTypeAndDefaults() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            let notebook = """
                {
                  "cells": [
                    {
                      "cell_type": "code",
                      "metadata": {},
                      "source": "def check_dob(dob: str, currentDate: str = \\"20260301\\") -> bool:\\n    return dob < currentDate\\n"
                    }
                  ],
                  "metadata": {}, "nbformat": 4, "nbformat_minor": 5
                }
                """

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebook)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string

                    // paramTypes forwarded — the client needs these to pick the
                    // right coercion for each cell.
                    #expect(
                        body.contains("\"paramTypes\""),
                        "paramTypes missing from DTO: \(body.prefix(500))")
                    #expect(
                        body.contains("\"str\""),
                        "Expected param type 'str' in forwarded paramTypes: \(body.prefix(500))")

                    // returnType forwarded — drives Expected-column coercion.
                    #expect(
                        body.contains("\"returnType\""),
                        "returnType missing from DTO: \(body.prefix(500))")
                    #expect(
                        body.contains("\"bool\""),
                        "Expected returnType 'bool' forwarded: \(body.prefix(500))")

                    // paramHasDefault forwarded — the editor uses this to let
                    // the instructor leave that cell empty so Python's default
                    // binds at test time.
                    #expect(
                        body.contains("\"paramHasDefault\""),
                        "paramHasDefault missing from DTO: \(body.prefix(500))")
                    // First param has no default, second does — verify the
                    // array is [false,true] (serialization may include
                    // whitespace, so both common forms pass).
                    #expect(
                        body.contains("[false,true]") || body.contains("[ false, true ]")
                            || body.contains("[false, true]"),
                        "Expected paramHasDefault [false, true]: \(body.prefix(500))")

                    // isShadowed forwarded — client disables overload options
                    // that Python would silently skip at runtime.
                    #expect(
                        body.contains("\"isShadowed\""),
                        "isShadowed missing from DTO: \(body.prefix(500))")
                }
            )

        }
    }

    @Test func scanNotebookIgnoresPrivateFunctions() async throws {
        try await withApp(try await makeApp()) { app in
            let cookie = try await loginAsInstructor(on: app)
            let (csrf, sessionCookie) = try await csrfFields(for: "/login", cookie: cookie, on: app)

            let notebookWithPrivate = """
                {
                  "cells": [
                    {
                      "cell_type": "code",
                      "metadata": {},
                      "source": "def _helper(x):\\n    pass\\ndef public_fn(x):\\n    pass\\n"
                    }
                  ],
                  "metadata": {},
                  "nbformat": 4,
                  "nbformat_minor": 5
                }
                """

            try await app.asyncTest(
                .POST, "/instructor/scan-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: sessionCookie)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: notebookWithPrivate)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = res.body.string
                    #expect(
                        body.contains("\"public_fn\""),
                        "Expected public_fn in response, got: \(body.prefix(500))")
                    #expect(
                        body.contains("\"_helper\"") == false,
                        "Private function should be excluded, got: \(body.prefix(500))")
                }
            )

        }
    }
}
