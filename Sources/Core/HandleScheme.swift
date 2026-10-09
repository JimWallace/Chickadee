// Core/HandleScheme.swift
//
// The three ways to make a class handle. `AvatarHandle.make` draws a scheme by
// its weight, then a handle from that scheme. The lists are in
// AvatarHandle+Scientists.swift and AvatarHandle+Words.swift.

public enum HandleScheme: String, Codable, Sendable, CaseIterable {
    /// A positive disposition and a scientist: "Curious Noether", "Bold Wang Zhenyi".
    case scientist
    /// A thing from science and what a person does: "Photon Navigator".
    case scienceAndAgent
    /// One compound word: "Ionspark".
    case compound

    /// The relative chance of drawing this scheme. Equal weights give each
    /// scheme a chance of 1 in 3.
    public var weight: Int { 1 }

    /// How many handles this scheme can make.
    public var combinationCount: Int {
        switch self {
        case .scientist: AvatarHandle.dispositions.count * AvatarHandle.scientists.count
        case .scienceAndAgent: AvatarHandle.scienceWords.count * AvatarHandle.agents.count
        case .compound: AvatarHandle.compoundPrefixes.count * AvatarHandle.compoundSuffixes.count
        }
    }

    /// Every handle this scheme can make.
    public var allHandles: [String] {
        switch self {
        case .scientist: Lists.scientistHandles
        case .scienceAndAgent: Lists.scienceAndAgentHandles
        case .compound: Lists.compoundHandles
        }
    }

    /// Whether this scheme can make `handle` from the current lists.
    public func canMake(_ handle: String) -> Bool {
        switch self {
        case .scientist:
            return Self.scientistName(in: handle) != nil
        case .scienceAndAgent:
            let words = handle.split(separator: " ", omittingEmptySubsequences: false)
            return words.count == 2
                && Lists.scienceWords.contains(String(words[0])) && Lists.agents.contains(String(words[1]))
        case .compound:
            return Lists.compoundSet.contains(handle)
        }
    }

    /// A handle from this scheme that is not in `taken`, or nil when this
    /// scheme has none left for the course.
    func make<G: RandomNumberGenerator>(excluding taken: Set<String>, using generator: inout G) -> String? {
        if self == .scientist {
            // Prefer a person nobody in the course has yet. Any disposition is
            // then free, because no handle in `taken` names that person.
            let used = Set(taken.compactMap(Self.scientistName(in:)))
            let unused = AvatarHandle.scientists.filter { !used.contains($0.name) }
            if let person = unused.randomElement(using: &generator),
                let disposition = AvatarHandle.dispositions.randomElement(using: &generator)
            {
                return "\(disposition) \(person.name)"
            }
        }
        // Pick from the unused remainder rather than guessing and retrying: a
        // retry loop degrades exactly when a course is large.
        return allHandles.filter { !taken.contains($0) }.randomElement(using: &generator)
    }

    /// The scientist's name in a handle of the first scheme, or nil when the
    /// handle is not one: "Bold Wang Zhenyi" gives "Wang Zhenyi".
    static func scientistName(in handle: String) -> String? {
        guard let space = handle.firstIndex(of: " ") else { return nil }
        let name = String(handle[handle.index(after: space)...])
        guard Lists.dispositions.contains(String(handle[..<space])), Lists.scientistNames.contains(name) else {
            return nil
        }
        return name
    }

    /// The lists as sets and the full handle lists, built once.
    private enum Lists {
        static let dispositions = Set(AvatarHandle.dispositions)
        static let scientistNames = Set(AvatarHandle.scientists.map(\.name))
        static let scienceWords = Set(AvatarHandle.scienceWords)
        static let agents = Set(AvatarHandle.agents)

        static let scientistHandles = AvatarHandle.dispositions.flatMap { disposition in
            AvatarHandle.scientists.map { "\(disposition) \($0.name)" }
        }
        static let scienceAndAgentHandles = AvatarHandle.scienceWords.flatMap { word in
            AvatarHandle.agents.map { "\(word) \($0)" }
        }
        static let compoundHandles = AvatarHandle.compoundPrefixes.flatMap { prefix in
            AvatarHandle.compoundSuffixes.map { prefix + $0 }
        }
        static let compoundSet = Set(compoundHandles)
    }
}
