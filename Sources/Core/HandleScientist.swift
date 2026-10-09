// Core/HandleScientist.swift
//
// One person a class handle can name: "Curious Noether", "Bold Wang Zhenyi".
// The selection rules are in docs/student-avatars.md §3. The fields beyond
// `name` are there so that a reviewer can check the list for balance
// (Tools/handle-review), and so that a page can later say who the person was.

public struct HandleScientist: Codable, Sendable, Hashable {

    /// Where the person did most of their work, for the balance review.
    public enum Region: String, Codable, Sendable, CaseIterable {
        case africa, eastAsia, europe, latinAmerica, northAmerica, oceania, southAsia, westAndCentralAsia
    }

    /// `both` marks one entry that names two people who share a surname.
    public enum Gender: String, Codable, Sendable, CaseIterable {
        case woman, man, both
    }

    /// The name in the handle: the name the person is known by, in one or
    /// two words ("Noether", "Wang Zhenyi", "Joliot-Curie").
    public let name: String
    public let fullName: String
    public let field: String
    /// For display only: "1882–1935", "c. 780–850", "born 1959".
    public let years: String
    /// A living person must be checked again before each term.
    public let isLiving: Bool
    public let region: Region
    public let gender: Gender
    public let note: String

    public init(
        _ name: String, fullName: String, field: String, years: String, isLiving: Bool = false,
        region: Region, gender: Gender, note: String
    ) {
        self.name = name
        self.fullName = fullName
        self.field = field
        self.years = years
        self.isLiving = isLiving
        self.region = region
        self.gender = gender
        self.note = note
    }
}
