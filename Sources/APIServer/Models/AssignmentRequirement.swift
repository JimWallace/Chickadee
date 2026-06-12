import Core
import Fluent
import Vapor

final class AssignmentRequirement: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "assignment_requirements"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "assignment_id")
    var assignmentID: UUID

    @OptionalField(key: "required_platform")
    var requiredPlatform: String?

    @OptionalField(key: "required_architecture")
    var requiredArchitecture: String?

    @Field(key: "required_languages_json")
    var requiredLanguagesJSON: String

    @Field(key: "required_capabilities_json")
    var requiredCapabilitiesJSON: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        assignmentID: UUID,
        specification: AssignmentRequirementSpec
    ) {
        self.assignmentID = assignmentID
        self.requiredPlatform = specification.requiredPlatform
        self.requiredArchitecture = specification.requiredArchitecture
        self.requiredLanguagesJSON = Self.encodeJSON(specification.requiredLanguages)
        self.requiredCapabilitiesJSON = Self.encodeJSON(specification.requiredCapabilities)
    }

    var requirementSpec: AssignmentRequirementSpec {
        get {
            AssignmentRequirementSpec(
                requiredPlatform: requiredPlatform,
                requiredArchitecture: requiredArchitecture,
                requiredLanguages: Self.decodeJSON(requiredLanguagesJSON, defaultValue: []),
                requiredCapabilities: Self.decodeJSON(requiredCapabilitiesJSON, defaultValue: [])
            )
        }
        set {
            requiredPlatform = newValue.requiredPlatform
            requiredArchitecture = newValue.requiredArchitecture
            requiredLanguagesJSON = Self.encodeJSON(newValue.requiredLanguages)
            requiredCapabilitiesJSON = Self.encodeJSON(newValue.requiredCapabilities)
        }
    }
}

private extension AssignmentRequirement {
    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return string
    }

    static func decodeJSON<T: Decodable>(_ raw: String, defaultValue: T) -> T {
        guard let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(T.self, from: data)
        else {
            return defaultValue
        }
        return decoded
    }
}
