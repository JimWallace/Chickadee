// Core/AvatarHandleScientist.swift
//
// One person in the "disposition + scientist" handle scheme.  The table itself
// is in AvatarHandleScientists.swift.

import Foundation

extension AvatarHandle {

    /// One person in the scientist scheme: one line of `scientistRecords`.
    public struct Scientist: Equatable, Sendable {

        /// Where the person did their main work, for the balance target of at
        /// most 35% from Europe.
        public enum Region: String, CaseIterable, Sendable {
            case africa = "Africa"
            case eastAsia = "East Asia"
            case europe = "Europe"
            case latinAmerica = "Latin America"
            case northAmerica = "North America"
            case oceania = "Oceania"
            case southAsia = "South Asia"
            case westAndCentralAsia = "West & Central Asia"
        }

        /// For the balance target of at least 40% women.  `maleAndFemale` is an
        /// entry that names two people with the same surname.
        public enum Gender: String, CaseIterable, Sendable {
            case female = "F"
            case male = "M"
            case maleAndFemale = "M+F"
        }

        /// The name in the handle: one or two words.
        public let handle: String
        public let fullName: String
        public let field: String
        /// A year; "~" marks an approximate year and a negative year is BCE.
        public let born: String
        /// The year of death, or nil when the person is alive.
        public let died: String?
        public let region: Region
        public let gender: Gender
        public let note: String

        /// Whether the person is alive.  Check every living person again
        /// before each term.
        public var isLiving: Bool { died == nil }

        /// Parses one line of `scientistRecords`, in Unicode NFC form.  Nil
        /// when the line does not have eight fields, a required field is
        /// empty, or the region or gender is unknown.
        public init?(record: Substring) {
            let fields = record.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            }
            guard fields.count == 8,
                [0, 1, 2, 3, 7].allSatisfy({ !fields[$0].isEmpty }),
                let region = Region(rawValue: fields[5]),
                let gender = Gender(rawValue: fields[6])
            else { return nil }
            handle = fields[0]
            fullName = fields[1]
            field = fields[2]
            born = fields[3]
            died = fields[4].isEmpty ? nil : fields[4]
            self.region = region
            self.gender = gender
            note = fields[7]
        }
    }
}
