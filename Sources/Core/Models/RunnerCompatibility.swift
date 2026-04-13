import Foundation

public struct RunnerCapability: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct LanguageVersion: Codable, Hashable, Sendable {
    public let language: String
    public let version: String

    public init(language: String, version: String) {
        self.language = language
        self.version = version
    }
}

public struct AssignmentLanguageRequirement: Codable, Hashable, Sendable {
    public let language: String
    public let minimumVersion: String?
    public let exactVersion: String?

    public init(language: String, minimumVersion: String? = nil, exactVersion: String? = nil) {
        self.language = language
        self.minimumVersion = minimumVersion
        self.exactVersion = exactVersion
    }
}

public struct RunnerCapabilityProfile: Codable, Equatable, Sendable {
    public let platform: String
    public let architecture: String
    public let languageVersions: [LanguageVersion]
    public let capabilities: [RunnerCapability]

    public init(
        platform: String,
        architecture: String,
        languageVersions: [LanguageVersion] = [],
        capabilities: [RunnerCapability] = []
    ) {
        self.platform = platform
        self.architecture = architecture
        self.languageVersions = languageVersions
        self.capabilities = capabilities
    }
}

public struct AssignmentRequirementSpec: Codable, Equatable, Sendable {
    public let requiredPlatform: String?
    public let requiredArchitecture: String?
    public let requiredLanguages: [AssignmentLanguageRequirement]
    public let requiredCapabilities: [RunnerCapability]

    public init(
        requiredPlatform: String? = nil,
        requiredArchitecture: String? = nil,
        requiredLanguages: [AssignmentLanguageRequirement] = [],
        requiredCapabilities: [RunnerCapability] = []
    ) {
        self.requiredPlatform = requiredPlatform
        self.requiredArchitecture = requiredArchitecture
        self.requiredLanguages = requiredLanguages
        self.requiredCapabilities = requiredCapabilities
    }
}

public struct CompatibilityResult: Codable, Equatable, Sendable {
    public let isCompatible: Bool
    public let reasons: [String]

    public init(isCompatible: Bool, reasons: [String] = []) {
        self.isCompatible = isCompatible
        self.reasons = reasons
    }

    public var summaryDescription: String {
        if reasons.isEmpty {
            return isCompatible ? "compatible" : "incompatible"
        }
        return reasons.joined(separator: "; ")
    }
}
