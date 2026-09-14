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
        self.requiredLanguagesJSON = JSONColumn.encode(specification.requiredLanguages)
        self.requiredCapabilitiesJSON = JSONColumn.encode(specification.requiredCapabilities)
    }

    var requirementSpec: AssignmentRequirementSpec {
        get {
            AssignmentRequirementSpec(
                requiredPlatform: requiredPlatform,
                requiredArchitecture: requiredArchitecture,
                requiredLanguages: JSONColumn.decode(requiredLanguagesJSON, defaultValue: []),
                requiredCapabilities: JSONColumn.decode(requiredCapabilitiesJSON, defaultValue: [])
            )
        }
        set {
            requiredPlatform = newValue.requiredPlatform
            requiredArchitecture = newValue.requiredArchitecture
            requiredLanguagesJSON = JSONColumn.encode(newValue.requiredLanguages)
            requiredCapabilitiesJSON = JSONColumn.encode(newValue.requiredCapabilities)
        }
    }
}
