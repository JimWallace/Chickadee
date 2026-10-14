// Tests/CoreTests/AvatarExpressionReplacementTests.swift

import Core
import Foundation
import Testing

/// `intrigued` replaced `startled`, name and art (docs/student-avatars.md,
/// "Replacing an expression"). The old raw value decodes as the new case,
/// for good: no migration rewrites the rows.
@Suite struct AvatarExpressionReplacementTests {

    @Test func startledIsGoneAndIntriguedIsAStarter() {
        #expect(AvatarExpression(rawValue: "startled") == nil)
        #expect(AvatarExpression.starterCases.contains(.intrigued))
        #expect(!AvatarExpression.starterCases.contains { $0.rawValue == "startled" })
    }

    @Test func theOldRawValueDecodesAsTheNewCase() throws {
        #expect(AvatarExpression(storedRawValue: "startled") == .intrigued)
        #expect(AvatarExpression(storedRawValue: "intrigued") == .intrigued)
        #expect(AvatarExpression(storedRawValue: "keen") == .keen)
        #expect(AvatarExpression(storedRawValue: "alarmed") == nil)

        let json =
            #"{"cap":"plum","wing":"barred","expression":"startled","accessory":"scarf","accent":"honey","backdrop":"rose"}"#
        let spec = try JSONDecoder().decode(AvatarSpec.self, from: Data(json.utf8))
        #expect(spec.expression == .intrigued)
        // Re-encoding writes the new name, so a save from the picker retires the old one.
        let encoded = try #require(String(data: JSONEncoder().encode(spec), encoding: .utf8))
        #expect(encoded.contains("\"intrigued\""))
        #expect(!encoded.contains("startled"))
    }

    @Test func anUnknownExpressionStillFailsToDecode() {
        let json =
            #"{"cap":"plum","wing":"barred","expression":"alarmed","accessory":"scarf","accent":"honey","backdrop":"rose"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AvatarSpec.self, from: Data(json.utf8))
        }
    }

    @Test func everyLegacyValueNamesACurrentCaseAndNoCurrentRawValue() {
        for (old, new) in AvatarExpression.legacyRawValues {
            #expect(AvatarExpression(rawValue: old) == nil, "\(old) is both legacy and current")
            #expect(AvatarExpression.allCases.contains(new))
        }
    }
}
