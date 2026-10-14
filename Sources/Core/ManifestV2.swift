// Core/ManifestV2.swift
//
// The `schemaVersion: 2` form of the manifest (docs/manifest-format-v2.md,
// D4 to D8 and D10).  It holds the same information as the v1 form in a
// different shape:
//
// - `github` groups the three GitHub settings.
// - `awards` groups the achievements and the disabled built-in awards.  Its
//   presence replaces `builtInAchievementsSeeded`.
// - `language` is one key: a language name, "none", or absent (undeclared).
// - `inputs`, at the top level and on each section, holds literal values and
//   `=` expressions in one list.
// - `files` gives each file its roles: required, grader-only, starter
//   notebook, and per-student dataset.
// - A suite entry has an `origin` object in place of `generatedBy` and
//   `generatedByCheck`.
// - The legacy `patternFamilies` and `notebookChecks` mirrors are gone;
//   `testItems` is the only list.
//
// `TestProperties.init(from:)` reads this form when `schemaVersion` is 2.
// The server's storage writer (`encodeManifest`) writes it through
// `TestProperties.v2Envelope()`, which returns nil for a manifest that the v2
// form cannot hold exactly, so that manifest stays v1.  Every path that sends
// a manifest out of the server sends v1.

import Foundation

/// The v2 wire form of a manifest.
public struct ManifestV2: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    var gradingMode: GradingMode
    var submissionMode: SubmissionMode
    var github: GitHub?
    var files: [File]
    var testSuites: [Entry]
    var timeLimitSeconds: Int
    var makefile: MakefileConfig?
    /// A language name, "none", or nil for undeclared.
    var language: String?
    var minimumRunnerVersion: String?
    var activity: ClassActivity?
    var testItems: [TestItem]
    var sections: [Section]
    var inputs: [Input]
    var awards: Awards?

    struct GitHub: Codable, Equatable, Sendable {
        var submission: Bool?
        var statusChecks: Bool?
        var starterRepository: String?
    }

    struct Awards: Codable, Equatable, Sendable {
        var achievements: [Achievement]?
        var disabledBuiltIns: [String]?
    }

    struct File: Codable, Equatable, Sendable {
        var name: String
        var required: Bool?
        var graderOnly: Bool?
        var starterNotebook: Bool?
        var dataset: DatasetSpec?
    }

    struct Input: Codable, Equatable, Sendable {
        var name: String
        /// Set for a literal input.  A literal can be JSON `null`, so the
        /// decoder tests for the key rather than for a non-null value.
        var value: JSONValue?
        /// Set for an `=` expression input.
        var expression: String?

        private enum CodingKeys: String, CodingKey { case name, value, expression }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            value = c.contains(.value) ? try c.decode(JSONValue.self, forKey: .value) : nil
            expression = try c.decodeIfPresent(String.self, forKey: .expression)
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            if let value { try c.encode(value, forKey: .value) }
            try c.encodeIfPresent(expression, forKey: .expression)
        }
    }

    struct Section: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var inputs: [Input]?
    }

    /// A suite entry.  The v1 entry keys, with `origin` in place of the two
    /// generator fields.
    struct Entry: Codable, Equatable, Sendable {
        var entry: TestSuiteEntry

        private struct Origin: Codable, Equatable {
            var family: String?
            var check: String?
        }

        private enum OriginKey: String, CodingKey { case origin }

        init(_ entry: TestSuiteEntry) { self.entry = entry }

        init(from decoder: any Decoder) throws {
            var entry = try TestSuiteEntry(from: decoder)
            let c = try decoder.container(keyedBy: OriginKey.self)
            let origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
            entry.generatedBy = origin?.family
            entry.generatedByCheck = origin?.check
            self.entry = entry
        }

        func encode(to encoder: any Encoder) throws {
            var bare = entry
            bare.generatedBy = nil
            bare.generatedByCheck = nil
            try bare.encode(to: encoder)
            var c = encoder.container(keyedBy: OriginKey.self)
            switch entry.origin {
            case .handWritten: break
            case .family(let id): try c.encode(Origin(family: id), forKey: .origin)
            case .check(let id): try c.encode(Origin(check: id), forKey: .origin)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, gradingMode, submissionMode, github, files, testSuites
        case timeLimitSeconds, makefile, language, minimumRunnerVersion, activity
        case testItems, sections, inputs, awards
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gradingMode = try c.decodeIfPresent(GradingMode.self, forKey: .gradingMode) ?? .worker
        submissionMode = try c.decodeIfPresent(SubmissionMode.self, forKey: .submissionMode) ?? .notebook
        github = try c.decodeIfPresent(GitHub.self, forKey: .github)
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        testSuites = try c.decodeIfPresent([Entry].self, forKey: .testSuites) ?? []
        timeLimitSeconds = try c.decodeIfPresent(Int.self, forKey: .timeLimitSeconds) ?? 10
        makefile = try c.decodeIfPresent(MakefileConfig.self, forKey: .makefile)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        minimumRunnerVersion = try c.decodeIfPresent(String.self, forKey: .minimumRunnerVersion)
        activity = try c.decodeIfPresent(ClassActivity.self, forKey: .activity)
        testItems = try c.decodeIfPresent([TestItem].self, forKey: .testItems) ?? []
        sections = try c.decodeIfPresent([Section].self, forKey: .sections) ?? []
        inputs = try c.decodeIfPresent([Input].self, forKey: .inputs) ?? []
        awards = try c.decodeIfPresent(Awards.self, forKey: .awards)
    }

    /// Writes only what differs from the defaults that `init(from:)` fills
    /// in, as the v1 encoder does.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schemaVersion, forKey: .schemaVersion)
        try c.encode(gradingMode, forKey: .gradingMode)
        try c.encode(submissionMode, forKey: .submissionMode)
        try c.encodeIfPresent(github, forKey: .github)
        if !files.isEmpty { try c.encode(files, forKey: .files) }
        try c.encode(testSuites, forKey: .testSuites)
        try c.encode(timeLimitSeconds, forKey: .timeLimitSeconds)
        try c.encodeIfPresent(makefile, forKey: .makefile)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(minimumRunnerVersion, forKey: .minimumRunnerVersion)
        try c.encodeIfPresent(activity, forKey: .activity)
        if !testItems.isEmpty { try c.encode(testItems, forKey: .testItems) }
        if !sections.isEmpty { try c.encode(sections, forKey: .sections) }
        if !inputs.isEmpty { try c.encode(inputs, forKey: .inputs) }
        try c.encodeIfPresent(awards, forKey: .awards)
    }
}

// MARK: - Conversion

extension ManifestV2 {
    static let noLanguage = "none"

    /// The v2 form of a manifest.  It can lose information; use
    /// `TestProperties.v2Envelope()`, which refuses a manifest that it cannot
    /// hold exactly.
    init(_ p: TestProperties) {
        gradingMode = p.gradingMode
        submissionMode = p.submissionMode
        let hasGitHub = p.githubSubmission || p.githubStatusChecks || p.githubStarterRepository != nil
        github =
            hasGitHub
            ? GitHub(
                submission: p.githubSubmission ? true : nil,
                statusChecks: p.githubStatusChecks ? true : nil,
                starterRepository: p.githubStarterRepository)
            : nil
        files = Self.files(of: p)
        testSuites = p.testSuites.map(Entry.init)
        timeLimitSeconds = p.timeLimitSeconds
        makefile = p.makefile
        switch p.languageDeclaration {
        case .undeclared: language = nil
        case .noLanguage: language = Self.noLanguage
        case .language(let declared): language = declared.rawValue
        }
        minimumRunnerVersion = p.minimumRunnerVersion
        activity = p.activity
        testItems = p.testItems
        sections = p.sections.map { section in
            let inputs = Self.inputs(variables: section.variables, expressions: section.expressions)
            return Section(id: section.id, name: section.name, inputs: inputs.isEmpty ? nil : inputs)
        }
        inputs = Self.inputs(variables: p.globalVariables, expressions: p.globalExpressions)
        let hasAwards =
            p.builtInAchievementsSeeded || !p.achievements.isEmpty || !p.disabledBuiltInAwardIDs.isEmpty
        awards =
            hasAwards
            ? Awards(
                achievements: p.achievements.isEmpty ? nil : p.achievements,
                disabledBuiltIns: p.disabledBuiltInAwardIDs.isEmpty ? nil : p.disabledBuiltInAwardIDs)
            : nil
    }

    /// The manifest that this envelope holds.  Its `schemaVersion` is the v1
    /// number, like every in-memory manifest: the writer, not the value,
    /// decides the wire version.
    var testProperties: TestProperties {
        get throws {
            var p = TestProperties(
                schemaVersion: TestProperties.v1SchemaVersion,
                gradingMode: gradingMode,
                submissionMode: submissionMode,
                githubSubmission: github?.submission ?? false,
                githubStatusChecks: github?.statusChecks ?? false,
                githubStarterRepository: github?.starterRepository,
                requiredFiles: files.filter { $0.required == true }.map(\.name),
                testSuites: testSuites.map(\.entry),
                timeLimitSeconds: timeLimitSeconds,
                makefile: makefile,
                starterNotebook: files.first { $0.starterNotebook == true }?.name,
                language: nil,
                minimumRunnerVersion: minimumRunnerVersion,
                activity: activity,
                sections: sections.map { section in
                    TestSuiteSection(
                        id: section.id, name: section.name,
                        variables: Self.variables(in: section.inputs ?? []),
                        expressions: Self.expressions(in: section.inputs ?? []))
                },
                globalVariables: Self.variables(in: inputs),
                globalExpressions: Self.expressions(in: inputs),
                datasets: files.compactMap(\.dataset),
                graderOnlyFiles: files.filter { $0.graderOnly == true }.map(\.name),
                achievements: awards?.achievements ?? [],
                disabledBuiltInAwardIDs: awards?.disabledBuiltIns ?? [],
                builtInAchievementsSeeded: awards != nil)
            p.testItems = testItems
            p.languageDeclaration = try Self.declaration(language)
            try validate()
            return p
        }
    }

    /// Refuses a hand-written v2 document whose meaning is not clear, rather
    /// than guess.  Nothing stores v2 that has not passed this check, so a
    /// refusal happens only while authoring.
    private func validate() throws {
        func refuse(_ reason: String) -> DecodingError {
            DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: reason))
        }
        for input in inputs + sections.flatMap({ $0.inputs ?? [] }) {
            guard (input.value == nil) != (input.expression == nil) else {
                throw refuse("Input \"\(input.name)\" must have exactly one of value and expression")
            }
        }
        for file in files {
            if let dataset = file.dataset, dataset.file != file.name {
                throw refuse("File \"\(file.name)\" has a dataset for \"\(dataset.file)\"")
            }
        }
        guard files.filter({ $0.starterNotebook == true }).count <= 1 else {
            throw refuse("More than one file is marked as the starter notebook")
        }
    }

    private static func declaration(_ language: String?) throws -> LanguageDeclaration {
        guard let language else { return .undeclared }
        if language == noLanguage { return .noLanguage }
        guard let declared = AssignmentLanguage(rawValue: language) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [CodingKeys.language],
                    debugDescription: "Unknown manifest language \"\(language)\""))
        }
        return .language(declared)
    }

    /// One entry per file name, in the order in which each name first occurs
    /// in the required files, the grader-only files, the datasets and the
    /// starter notebook.
    private static func files(of p: TestProperties) -> [File] {
        var files: [File] = []
        func update(_ name: String, _ change: (inout File) -> Void) {
            if let index = files.firstIndex(where: { $0.name == name }) {
                change(&files[index])
            } else {
                var file = File(name: name)
                change(&file)
                files.append(file)
            }
        }
        for name in p.requiredFiles { update(name) { $0.required = true } }
        for name in p.graderOnlyFiles { update(name) { $0.graderOnly = true } }
        for spec in p.datasets { update(spec.file) { $0.dataset = spec } }
        if let notebook = p.starterNotebook { update(notebook) { $0.starterNotebook = true } }
        return files
    }

    private static func inputs(
        variables: [FamilyVariable], expressions: [PersonalizationExpression]
    ) -> [Input] {
        variables.map { Input(name: $0.name, value: $0.value) }
            + expressions.map { Input(name: $0.name, expression: $0.expression) }
    }

    private static func variables(in inputs: [Input]) -> [FamilyVariable] {
        inputs.compactMap { input in input.value.map { FamilyVariable(name: input.name, value: $0) } }
    }

    private static func expressions(in inputs: [Input]) -> [PersonalizationExpression] {
        inputs.compactMap { input in
            guard input.value == nil, let expression = input.expression else { return nil }
            return PersonalizationExpression(name: input.name, expression: expression)
        }
    }
}

extension ManifestV2.File {
    init(name: String) { self.name = name }
}

extension ManifestV2.Input {
    init(name: String, value: JSONValue) {
        self.name = name
        self.value = value
    }

    init(name: String, expression: String) {
        self.name = name
        self.expression = expression
    }
}

extension TestProperties {
    /// The v2 form of this manifest, or nil when the v2 form cannot hold it
    /// exactly.  A manifest that sets both generator fields on one entry, has
    /// a language without its declaration flag, or lists a file name twice in
    /// one list is such a manifest; the writer keeps it in v1.
    ///
    /// The check decodes the encoded bytes and compares the decoded value,
    /// not the in-memory envelope: some losses happen only in the encoding
    /// (an entry's `origin` holds one generator).
    public func v2Envelope() -> ManifestV2? {
        let envelope = ManifestV2(self)
        guard let data = try? ManifestCodec.stableEncoder.encode(envelope),
            let roundTripped = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
        else { return nil }
        return roundTripped == self ? envelope : nil
    }

    /// The `schemaVersion` that stored manifest text carries, read without a
    /// full decode, or nil when the text has none.  The in-memory value does
    /// not keep it (see `ManifestV2.testProperties`), so a caller that must
    /// know how the text was written asks the text.
    public static func wireVersion(of text: String) -> Int? {
        struct VersionOnly: Decodable { let schemaVersion: Int? }
        return (try? ManifestCodec.decoder.decode(VersionOnly.self, from: Data(text.utf8)))?.schemaVersion
    }
}
