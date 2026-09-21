import Foundation

public struct RunnerCapability: Codable, Hashable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    /// Advertised by every runner build that can stage a class-activity
    /// opponent (docs/class-activities.md). A BUILD capability, not a host
    /// one: nothing has to be installed, the runner just has to know how to
    /// read `Job.opponent`. An older build never advertises it, and the claim
    /// gate keeps match jobs away from such a runner — which would otherwise
    /// grade a bot match with no bot in the workspace.
    public static let activityMatch = RunnerCapability(name: "activity-match")

    /// Advertised by every runner build that can stage another SUBMISSION as
    /// the opponent (king of the hill; later, classmates). Separate from
    /// `activityMatch` because a build that copies a support file may predate
    /// downloading and extracting a submission, and a match handed to such a
    /// build would fail — loudly, but for every student until a runner is
    /// upgraded, where the gate makes it wait instead.
    public static let activityOpponentSubmission = RunnerCapability(name: "activity-opponent-submission")

    /// Advertised by every runner build that can play one job against MANY
    /// opponents (`Job.opponents`, round robin) and report the per-match rows.
    /// A build that stages one opponent would ignore the list and grade the
    /// suite once with nobody staged, so the gate makes such a job wait.
    public static let activityMatrix = RunnerCapability(name: "activity-matrix")
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
