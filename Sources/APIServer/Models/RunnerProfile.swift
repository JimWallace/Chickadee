import Core
import Fluent
import Vapor

final class RunnerProfile: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: mutated only within Vapor's request context.
    static let schema = "runner_profiles"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "runner_id")
    var runnerID: String

    @OptionalField(key: "display_name")
    var displayName: String?

    @Field(key: "platform")
    var platform: String

    @Field(key: "architecture")
    var architecture: String

    @Field(key: "language_versions_json")
    var languageVersionsJSON: String

    @Field(key: "capabilities_json")
    var capabilitiesJSON: String

    @OptionalField(key: "profile_hash")
    var profileHash: String?

    @Field(key: "last_registered_at")
    var lastRegisteredAt: Date

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    @Field(key: "is_active")
    var isActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        runnerID: String,
        displayName: String? = nil,
        profile: RunnerCapabilityProfile,
        profileHash: String?,
        lastRegisteredAt: Date,
        lastSeenAt: Date,
        isActive: Bool = true
    ) {
        self.runnerID = runnerID
        self.displayName = displayName
        self.platform = profile.platform
        self.architecture = profile.architecture
        self.languageVersionsJSON = Self.encodeJSON(profile.languageVersions)
        self.capabilitiesJSON = Self.encodeJSON(profile.capabilities)
        self.profileHash = profileHash
        self.lastRegisteredAt = lastRegisteredAt
        self.lastSeenAt = lastSeenAt
        self.isActive = isActive
    }

    var capabilityProfile: RunnerCapabilityProfile {
        get {
            RunnerCapabilityProfile(
                platform: platform,
                architecture: architecture,
                languageVersions: Self.decodeJSON(languageVersionsJSON, defaultValue: []),
                capabilities: Self.decodeJSON(capabilitiesJSON, defaultValue: [])
            )
        }
        set {
            platform = newValue.platform
            architecture = newValue.architecture
            languageVersionsJSON = Self.encodeJSON(newValue.languageVersions)
            capabilitiesJSON = Self.encodeJSON(newValue.capabilities)
        }
    }
}

private extension RunnerProfile {
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
