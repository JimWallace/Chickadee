// APIServer/Utilities/AuthoringValidationError.swift
//
// The rules an authored assignment can break, one case per rule (#1929).

import Core
import Foundation

/// A rule that authored assignment content breaks.
///
/// The authoring validators used to throw `Abort(.unprocessableEntity,
/// reason:)` with a hand-written sentence at each site, which made them
/// import Vapor for one type and left no way to ask which rule failed except
/// by matching text. Each case names one rule; `description` is the sentence
/// the validator used to write, word for word, so a page or an MCP agent
/// reads the same message as before. The `AbortError` conformance (status
/// 422) lives beside the server code in `AuthoringValidationError+Abort.swift`,
/// so this file stays free of Vapor.
///
/// Cases are added one validator at a time. They cover
/// `NotebookCheckValidator`, `ManifestValidation` and `PatternKindHandler`;
/// the other authoring validators still throw `Abort`.
enum AuthoringValidationError: Error, Equatable, Sendable {
    // MARK: NotebookCheckValidator

    /// A notebook check's id is not a valid filename fragment.
    case invalidNotebookCheckID(String)
    /// Two notebook checks share an id.
    case duplicateNotebookCheckID(String)
    /// A notebook check has negative points.
    case negativeNotebookCheckPoints(checkID: String)
    /// A notebook check would generate a file that a hand-written script
    /// already uses.
    case notebookCheckCollidesWithHandWrittenFile(checkID: String, filename: String)
    /// A notebook check would generate a file that a pattern family generates.
    case notebookCheckCollidesWithFamilyFile(checkID: String, filename: String)
    /// Two notebook checks would generate the same file.
    case notebookCheckCollidesWithCheckFile(checkID: String, filename: String)
    /// A kernel language cannot render this notebook-check kind.
    case notebookCheckKindUnsupported(
        checkID: String, kind: NotebookCheckKind, language: String,
        supportedKinds: [String], handWrittenExtension: String)
    /// An upload-only language has no notebook workflow, so no kind is
    /// available.
    case notebookCheckKindUnavailable(
        checkID: String, kind: NotebookCheckKind, language: AssignmentLanguage,
        reason: String, handWrittenExtension: String)
    /// A notebook check asks for regex matching in a language whose pattern
    /// syntax is not PCRE.
    case notebookCheckRegexUnsupported(
        checkID: String, kind: NotebookCheckKind, language: String, reason: String)

    // MARK: ManifestValidation

    /// A script depends on a script that is not in the suite.
    case unknownManifestDependency(script: String, dependency: String)
    /// A script depends on itself.
    case manifestScriptDependsOnItself(script: String)
    /// The suite's dependency graph has a cycle.
    case manifestDependencyCycle

    // MARK: PatternKindHandler

    /// A `programIO` case does not have exactly one string arg, its stdin.
    case programIOCaseNeedsStdinArg(familyID: String, caseKey: String)
    /// A `programIO` case's expected output is not a string.
    case programIOExpectedNotString(familyID: String, caseKey: String)
    /// A `programIO` case has an empty expected output under a comparison
    /// that an empty needle always satisfies.
    case programIOExpectedEmpty(familyID: String, caseKey: String, comparison: ProgramIOComparison)
    /// The assignment's language cannot use a `programIO` family's
    /// comparison.
    case programIOComparisonUnsupported(
        familyID: String, comparison: ProgramIOComparison, language: AssignmentLanguage, reason: String)
    /// A `programIO` case's expected output is not a valid regular
    /// expression.
    case programIOInvalidRegex(familyID: String, caseKey: String)
    /// A `differential` family has no reference implementation.
    case differentialReferenceMissing(familyID: String)
    /// A `differential` family's reference does not define the name that
    /// the generated test calls.
    case differentialReferenceMissingDefinition(familyID: String, referenceName: String, functionName: String)
    /// A case's arg count is not the family's parameter count. `kindLabel`
    /// is nil for the kinds whose message names no kind.
    case patternCaseArgCountMismatch(
        familyID: String, kindLabel: String?, caseKey: String, argCount: Int, parameterCount: Int)
    /// A family's tolerance is negative or not finite.
    case invalidPatternFamilyTolerance(familyID: String)
    /// A `variableEquality` case does not have exactly one arg.
    case variableEqualityArgCount(familyID: String, caseKey: String, argCount: Int)
    /// A `variableEquality` case's arg is not a non-empty string.
    case variableEqualityArgNotName(familyID: String, caseKey: String)
    /// A `variableEquality` case names a variable that is not a valid
    /// identifier in the assignment's language.
    case variableEqualityInvalidName(familyID: String, caseKey: String, name: String, language: AssignmentLanguage)
    /// A `returnTypeCheck` case's expected value is not a type name.
    case returnTypeCheckExpectedNotTypeName(familyID: String, caseKey: String)
    /// An `exceptionExpected` case's expected value is not an exception
    /// class name.
    case exceptionExpectedNotClassName(familyID: String, caseKey: String)
    /// A `performanceThreshold` case's expected value is not a positive
    /// number.
    case performanceThresholdNotPositive(familyID: String, caseKey: String)
    /// A `stdoutEquality` case's expected value is not a string.
    case stdoutEqualityExpectedNotString(familyID: String, caseKey: String)
    /// An `unorderedEquality` case's expected value is not a list.
    case unorderedEqualityExpectedNotList(familyID: String, caseKey: String)
}

extension AuthoringValidationError: CustomStringConvertible, LocalizedError {
    var description: String {
        switch self {
        case .invalidNotebookCheckID(let id):
            return "Notebook check id '\(id)' must contain only letters, digits, and underscore"
        case .duplicateNotebookCheckID(let id):
            return "Duplicate notebook check id '\(id)'"
        case .negativeNotebookCheckPoints(let checkID):
            return "Notebook check '\(checkID)': points must be non-negative"
        case .notebookCheckCollidesWithHandWrittenFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', but a hand-written file with that name already exists. Rename the file or change the check id."
        case .notebookCheckCollidesWithFamilyFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', which collides with a pattern family's generated filename. Change the check id."
        case .notebookCheckCollidesWithCheckFile(let checkID, let filename):
            return
                "Notebook check '\(checkID)' would generate '\(filename)', which collides with another check's generated file. Change the check id."
        case .notebookCheckKindUnsupported(
            let checkID, let kind, let language, let supportedKinds, let handWrittenExtension):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) is not supported for "
                + "\(language) assignments — supported kinds are: \(supportedKinds.joined(separator: ", ")). "
                + "Express this check as a hand-written \(handWrittenExtension) test for now."
        case .notebookCheckKindUnavailable(
            let checkID, let kind, let language, let reason, let handWrittenExtension):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) is not available for "
                + "\(language.displayName) assignments: \(reason) Use a pattern family or a "
                + "hand-written \(handWrittenExtension) test instead."
        case .notebookCheckRegexUnsupported(let checkID, let kind, let language, let reason):
            return "Notebook check '\(checkID)' (\(kind.rawValue)) uses regex matching, "
                + "which is not available for \(language) assignments: \(reason)"

        case .unknownManifestDependency(let script, let dependency):
            return
                "Manifest dependency error: '\(script)' depends on '\(dependency)', which is not listed in testSuites"
        case .manifestScriptDependsOnItself(let script):
            return "Manifest dependency error: '\(script)' cannot depend on itself"
        case .manifestDependencyCycle:
            return "Manifest dependency error: dependency graph contains a cycle"

        case .programIOCaseNeedsStdinArg(let familyID, let caseKey):
            return "Pattern family '\(familyID)' (program_io): case '\(caseKey)' must have exactly one "
                + "arg, the text fed to the program's standard input (a string, possibly empty)"
        case .programIOExpectedNotString(let familyID, let caseKey):
            return "Pattern family '\(familyID)' (program_io): case '\(caseKey)' expected must be a "
                + "string (the standard output to match)"
        case .programIOExpectedEmpty(let familyID, let caseKey, let comparison):
            return "Pattern family '\(familyID)' (program_io): case '\(caseKey)' expected must not be "
                + "empty for the \(comparison.rawValue) comparison — it would match any output"
        case .programIOComparisonUnsupported(let familyID, let comparison, let language, let reason):
            return "Pattern family '\(familyID)' (program_io): the \(comparison.rawValue) comparison "
                + "is not available on a \(language.displayName) assignment — \(reason)"
        case .programIOInvalidRegex(let familyID, let caseKey):
            return "Pattern family '\(familyID)' (program_io): case '\(caseKey)' expected is not a "
                + "valid regular expression"
        case .differentialReferenceMissing(let familyID):
            return """
                Pattern family '\(familyID)' (differential) has no reference \
                implementation. This kind computes each case's expected value by \
                running your reference, so there is nothing to compare against \
                without one.
                """
        case .differentialReferenceMissingDefinition(let familyID, let referenceName, let functionName):
            return """
                Pattern family '\(familyID)' (differential) must define \
                `\(referenceName)`, which is the name the generated \
                test calls. Rename your reference implementation to \
                `\(referenceName)` — it takes the same arguments as \
                `\(functionName)`.
                """
        case .patternCaseArgCountMismatch(let familyID, let kindLabel, let caseKey, let argCount, let parameterCount):
            let prefix = "Pattern family '\(familyID)'" + (kindLabel.map { " (\($0))" } ?? "")
            return
                "\(prefix): case '\(caseKey)' has \(argCount) arg(s) but family declares \(parameterCount) parameter(s)"
        case .invalidPatternFamilyTolerance(let familyID):
            return "Pattern family '\(familyID)': tolerance must be a non-negative finite number."
        case .variableEqualityArgCount(let familyID, let caseKey, let argCount):
            return
                "Pattern family '\(familyID)' (variable_equality): case '\(caseKey)' must have exactly one arg (the variable name); got \(argCount)"
        case .variableEqualityArgNotName(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (variable_equality): case '\(caseKey)' arg must be a non-empty string (the variable name)"
        case .variableEqualityInvalidName(let familyID, let caseKey, let name, let language):
            return "Pattern family '\(familyID)' (variable_equality): case '\(caseKey)' variable name "
                + "'\(name)' is not a valid \(identifierKindName(language))"
        case .returnTypeCheckExpectedNotTypeName(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (return_type_check): case '\(caseKey)' expected must be a non-empty string naming the type (e.g. \"int\", \"DataFrame\")"
        case .exceptionExpectedNotClassName(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (exception_expected): case '\(caseKey)' expected must be a non-empty string naming the exception class (e.g. \"ValueError\")"
        case .performanceThresholdNotPositive(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (performance_threshold): case '\(caseKey)' expected must be a positive number (milliseconds)"
        case .stdoutEqualityExpectedNotString(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (stdout_equality): case '\(caseKey)' expected must be a string (the captured stdout to match)"
        case .unorderedEqualityExpectedNotList(let familyID, let caseKey):
            return
                "Pattern family '\(familyID)' (unordered_equality): case '\(caseKey)' expected must be a list (the elements to match, in any order)"
        }
    }

    var errorDescription: String? { description }
}
