import Core
import Foundation

struct VersionComparator {
    func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let left = parse(lhs), let right = parse(rhs) else { return nil }
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private func parse(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = trimmed.prefix { $0.isNumber || $0 == "." }
        let normalized = allowed.isEmpty ? trimmed : String(allowed)
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, let value = Int(part) else { return nil }
            values.append(value)
        }
        return values
    }
}

struct CompatibilityMatcher {
    private let versionComparator = VersionComparator()

    func evaluate(
        runnerProfile: RunnerCapabilityProfile?,
        requirements: AssignmentRequirementSpec?
    ) -> CompatibilityResult {
        guard let requirements, requirements.hasRequirements else {
            return CompatibilityResult(isCompatible: true)
        }

        guard let runnerProfile else {
            return CompatibilityResult(isCompatible: false, reasons: ["runner profile unavailable"])
        }

        var reasons: [String] = []

        if let requiredPlatform = normalize(requirements.requiredPlatform),
           normalize(runnerProfile.platform) != requiredPlatform {
            reasons.append("platform \(runnerProfile.platform) != required \(requiredPlatform)")
        }

        if let requiredArchitecture = normalize(requirements.requiredArchitecture),
           normalize(runnerProfile.architecture) != requiredArchitecture {
            reasons.append("architecture \(runnerProfile.architecture) != required \(requiredArchitecture)")
        }

        let runnerLanguages = Dictionary(
            uniqueKeysWithValues: runnerProfile.languageVersions.map { (normalizedName($0.language), $0.version) }
        )
        for requirement in requirements.requiredLanguages {
            let language = normalizedName(requirement.language)
            guard let runnerVersion = runnerLanguages[language] else {
                reasons.append("missing language \(language)")
                continue
            }

            if let exactVersion = normalizedVersion(requirement.exactVersion) {
                guard let comparison = versionComparator.compare(runnerVersion, exactVersion) else {
                    reasons.append("unable to compare \(language) version \(runnerVersion) to required \(exactVersion)")
                    continue
                }
                if comparison != .orderedSame {
                    reasons.append("\(language) version \(runnerVersion) != required \(exactVersion)")
                }
                continue
            }

            if let minimumVersion = normalizedVersion(requirement.minimumVersion) {
                guard let comparison = versionComparator.compare(runnerVersion, minimumVersion) else {
                    reasons.append("unable to compare \(language) version \(runnerVersion) to required \(minimumVersion)")
                    continue
                }
                if comparison == .orderedAscending {
                    reasons.append("\(language) version \(runnerVersion) < required \(minimumVersion)")
                }
            }
        }

        let runnerCapabilities = Set(runnerProfile.capabilities.map { normalizedName($0.name) })
        for capability in requirements.requiredCapabilities.map(\.name).map(normalizedName) where !runnerCapabilities.contains(capability) {
            reasons.append("missing capability \(capability)")
        }

        return CompatibilityResult(isCompatible: reasons.isEmpty, reasons: reasons)
    }

    private func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedName(_ raw: String) -> String {
        normalize(raw) ?? raw.lowercased()
    }

    private func normalizedVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension AssignmentRequirementSpec {
    var hasRequirements: Bool {
        requiredPlatform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || requiredArchitecture?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !requiredLanguages.isEmpty
            || !requiredCapabilities.isEmpty
    }
}
