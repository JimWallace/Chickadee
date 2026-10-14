// Tests/APITests/EnvironmentSourceConfigReaderTests.swift
//
// `EnvironmentSource.get` reads through a Swift Configuration `ConfigReader`,
// the type Vapor 5 reads its settings through. These tests pin that the move
// changed nothing an operator sees: each variable is still read by its exact
// name, and a missing or blank variable still reads as missing.

import Testing

@testable import APIServer

@Suite struct EnvironmentSourceConfigReaderTests {

    /// The dotted key names exactly the variable it came from, for one-word,
    /// multi-word and digit-bearing names.
    @Test(arguments: ["PORT", "AUTH_MODE", "OIDC_AUTH_SERVER", "BRIGHTSPACE_LP_API_VERSION", "S3_BUCKET"])
    func theKeyNamesTheVariable(name: String) async throws {
        let value = try await withTestEnvironment([name: "value-of-\(name)"]) {
            EnvironmentSource.get(name)
        }
        #expect(value == "value-of-\(name)")
    }

    @Test func aMissingVariableReadsAsNil() async throws {
        let value = try await withTestEnvironment(["CHICKADEE_TEST_ABSENT": nil]) {
            EnvironmentSource.get("CHICKADEE_TEST_ABSENT")
        }
        #expect(value == nil)
    }

    /// The typed helpers still treat a blank value as unset and parse the rest.
    @Test func theTypedHelpersKeepTheirMeaning() async throws {
        let read = try await withTestEnvironment([
            "CHICKADEE_TEST_BLANK": "   ",
            "CHICKADEE_TEST_FLAG": "yes",
            "CHICKADEE_TEST_COUNT": "42",
        ]) {
            (
                trimmedEnv("CHICKADEE_TEST_BLANK"), environmentBool("CHICKADEE_TEST_FLAG"),
                environmentInt("CHICKADEE_TEST_COUNT")
            )
        }
        #expect(read.0 == nil)
        #expect(read.1 == true)
        #expect(read.2 == 42)
    }

    /// A neighbouring name does not leak into the read: `AUTH_MODE` is not
    /// `AUTH_MODE_EXTRA`.
    @Test func aLongerNameIsADifferentVariable() async throws {
        let value = try await withTestEnvironment(["AUTH_MODE": nil, "AUTH_MODE_EXTRA": "sso"]) {
            EnvironmentSource.get("AUTH_MODE")
        }
        #expect(value == nil)
    }
}
