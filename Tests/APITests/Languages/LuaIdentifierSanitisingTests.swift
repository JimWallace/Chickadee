// Tests/APITests/Languages/LuaIdentifierSanitisingTests.swift
//
// `luaIdentifier(_:)`, the Lua renderers' last guard on a name that slipped
// past validation. The coverage report showed that no test gave it a name it
// had to change. The result must always be a legal Lua local, so the
// generated script parses instead of the save failing.

import Testing

@testable import APIServer

@Suite struct LuaIdentifierSanitisingTests {

    @Test(arguments: ["total", "_count", "goal2", "x"])
    func aValidNameIsKept(name: String) {
        #expect(luaIdentifier(name) == name)
    }

    @Test(arguments: [
        ("my.value", "my_value"),
        ("total-count", "total_count"),
        ("2fast", "_2fast"),
        ("end", "end_"),
        ("", "_"),
        ("café", "caf_"),
    ])
    func anUnusableNameIsMadeLegal(name: String, expected: String) {
        let result = luaIdentifier(name)
        #expect(result == expected)
        #expect(isValidLuaIdentifier(result))
    }
}
