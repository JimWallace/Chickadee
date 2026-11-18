// Core/Models/FHIRDatasetSummary.swift
//
// What a FHIR NDJSON dataset holds, computed once when the file is checked
// (docs/fhir-datasets-plan.md §5). The Data page and MCP `get_dataset` show it
// in place of a CSV's column list. It is a description of the file and never
// changes what a student receives.
//
// It also holds the FHIR data dictionary, the one part an instructor writes:
// the prose of each resource type and each code, and the example resource
// the Data page shows. Prose sits on a fact the file has, so an entry the
// file lacks cannot be written; a new version carries the prose of every
// entry it still has (`carryingNotes(from:text:)`).

/// The counts and codes of one FHIR NDJSON file.
public struct FHIRDatasetSummary: Codable, Equatable, Sendable {
    /// The FHIR version every dataset is read as. A later R5 dataset is a new
    /// value here, not a migration.
    public static let readAsVersion = "4.0.1"
    /// How many distinct codes the summary lists before it stops.
    public static let maxListedCodes = 500
    /// The longest line that can be the example resource. The Data page shows
    /// it whole, and the version row stores it.
    public static let maxExampleBytes = 16_384

    /// Whether `line` is short enough to be the example. One rule for the
    /// profile's default, a picked example and a carried one.
    public static func fitsAsExample(_ line: String) -> Bool {
        line.utf8.count <= maxExampleBytes
    }
    /// The longest description of one type or code. A file lists up to
    /// `maxListedCodes` codes, and every version row stores the prose.
    public static let maxDescriptionCharacters = 1_000

    /// How many resources of one type the file holds.
    public struct TypeCount: Codable, Equatable, Sendable {
        public let resourceType: String
        public let count: Int
        /// The instructor's prose for the type, or nil.
        public var description: String?

        public init(resourceType: String, count: Int, description: String? = nil) {
            self.resourceType = resourceType
            self.count = count
            self.description = description
        }
    }

    /// One code in use: a coding in a resource's top-level `code` element.
    public struct CodeUse: Codable, Equatable, Sendable {
        public let resourceType: String
        /// The coding's `system` URI, or nil when the coding has none.
        public let system: String?
        public let code: String
        /// The first `display` seen for this code, or nil.
        public let display: String?
        /// How many resources carry the code.
        public let count: Int
        /// The distinct `valueQuantity.unit` values seen with the code, sorted.
        /// Empty for a resource type with no quantity.
        public let units: [String]
        /// The instructor's prose for the code, or nil.
        public var description: String?

        public init(
            resourceType: String, system: String?, code: String, display: String?, count: Int, units: [String],
            description: String? = nil
        ) {
            self.resourceType = resourceType
            self.system = system
            self.code = code
            self.display = display
            self.count = count
            self.units = units
            self.description = description
        }

        /// What names the code across versions: its type, system and code.
        public var key: CodeKey { CodeKey(resourceType: resourceType, system: system, code: code) }

        /// The system's name for a student: LOINC, SNOMED CT, ICD-10 or
        /// ICD-10-CM for the systems a course meets, else the URI itself.
        public var systemName: String? {
            system.map(Self.name(ofSystem:))
        }

        /// The name of a code system URI, or the URI when it is not one of the
        /// systems a course meets.
        public static func name(ofSystem system: String) -> String {
            switch system {
            case "http://loinc.org": return "LOINC"
            case "http://snomed.info/sct": return "SNOMED CT"
            case "http://hl7.org/fhir/sid/icd-10": return "ICD-10"
            case "http://hl7.org/fhir/sid/icd-10-cm": return "ICD-10-CM"
            default: return system
            }
        }
    }

    /// What names a code in the dictionary.
    public struct CodeKey: Codable, Hashable, Sendable {
        public let resourceType: String
        public let system: String?
        public let code: String

        public init(resourceType: String, system: String?, code: String) {
            self.resourceType = resourceType
            self.system = system
            self.code = code
        }
    }

    /// One resource of the file, as the Data page shows it.
    public struct ExampleResource: Codable, Equatable, Sendable {
        public let resourceType: String
        public let id: String
        /// The resource's line as the file holds it, without surrounding
        /// whitespace or the line ending.
        public let json: String

        public init(resourceType: String, id: String, json: String) {
            self.resourceType = resourceType
            self.id = id
            self.json = json
        }
    }

    public let fhirVersion: String
    /// Every resource in the file.
    public let resourceCount: Int
    /// The Patient resources, counted from the file, so a page can say
    /// "300 patients".
    public let patientCount: Int
    /// Each resource type with its count, sorted by type.
    public internal(set) var resourceTypes: [TypeCount]
    /// The codes in use, most used first, at most `maxListedCodes`.
    public internal(set) var codes: [CodeUse]
    /// How many distinct codes were left out of `codes`.
    public let omittedCodeCount: Int
    /// References of the form `Patient/<id>` in a `subject` or `patient`
    /// element that name no Patient in the file. The first release does not
    /// refuse them, because it delivers the whole file; the count lets the
    /// instructor see them.
    public let danglingPatientReferences: Int
    /// The resource the Data page shows. The profile picks the first
    /// Observation, else the first resource, no longer than
    /// `maxExampleBytes`; the instructor may pick another.
    public var example: ExampleResource?

    public init(
        fhirVersion: String, resourceCount: Int, patientCount: Int, resourceTypes: [TypeCount], codes: [CodeUse],
        omittedCodeCount: Int, danglingPatientReferences: Int, example: ExampleResource? = nil
    ) {
        self.example = example
        self.fhirVersion = fhirVersion
        self.resourceCount = resourceCount
        self.patientCount = patientCount
        self.resourceTypes = resourceTypes
        self.codes = codes
        self.omittedCodeCount = omittedCodeCount
        self.danglingPatientReferences = danglingPatientReferences
    }
}
