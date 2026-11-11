// Core/Models/FHIRDatasetSummary.swift
//
// What a FHIR NDJSON dataset holds, computed once when the file is checked
// (docs/fhir-datasets-plan.md §5). The Data page and MCP `get_dataset` show it
// in place of a CSV's column list. It is a description of the file and never
// changes what a student receives.

/// The counts and codes of one FHIR NDJSON file.
public struct FHIRDatasetSummary: Codable, Equatable, Sendable {
    /// The FHIR version every dataset is read as. A later R5 dataset is a new
    /// value here, not a migration.
    public static let readAsVersion = "4.0.1"
    /// How many distinct codes the summary lists before it stops.
    public static let maxListedCodes = 500

    /// How many resources of one type the file holds.
    public struct TypeCount: Codable, Equatable, Sendable {
        public let resourceType: String
        public let count: Int

        public init(resourceType: String, count: Int) {
            self.resourceType = resourceType
            self.count = count
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

        public init(
            resourceType: String, system: String?, code: String, display: String?, count: Int, units: [String]
        ) {
            self.resourceType = resourceType
            self.system = system
            self.code = code
            self.display = display
            self.count = count
            self.units = units
        }

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

    public let fhirVersion: String
    /// Every resource in the file.
    public let resourceCount: Int
    /// The Patient resources, counted from the file, so a page can say
    /// "300 patients".
    public let patientCount: Int
    /// Each resource type with its count, sorted by type.
    public let resourceTypes: [TypeCount]
    /// The codes in use, most used first, at most `maxListedCodes`.
    public let codes: [CodeUse]
    /// How many distinct codes were left out of `codes`.
    public let omittedCodeCount: Int
    /// References of the form `Patient/<id>` in a `subject` or `patient`
    /// element that name no Patient in the file. The first release does not
    /// refuse them, because it delivers the whole file; the count lets the
    /// instructor see them.
    public let danglingPatientReferences: Int

    public init(
        fhirVersion: String, resourceCount: Int, patientCount: Int, resourceTypes: [TypeCount], codes: [CodeUse],
        omittedCodeCount: Int, danglingPatientReferences: Int
    ) {
        self.fhirVersion = fhirVersion
        self.resourceCount = resourceCount
        self.patientCount = patientCount
        self.resourceTypes = resourceTypes
        self.codes = codes
        self.omittedCodeCount = omittedCodeCount
        self.danglingPatientReferences = danglingPatientReferences
    }
}
