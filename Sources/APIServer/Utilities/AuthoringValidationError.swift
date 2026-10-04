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
/// `NotebookCheckValidator`, `ManifestValidation`, `PatternKindHandler` and
/// `NotebookCheckKindHandler`. `PatternFamilyValidator` and
/// `PatternFamilyAuthoredGraph` still throw `Abort`, because tests assert
/// that concrete type.
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

    // MARK: NotebookCheckKindHandler

    /// A notebook check has no value for a required name field.
    case notebookCheckFieldMissing(checkID: String, kindLabel: String, field: String)
    /// A notebook check's name field is not a valid identifier in the
    /// assignment's language.
    case notebookCheckFieldNotIdentifier(
        checkID: String, kindLabel: String, field: String, value: String, language: AssignmentLanguage)
    /// A notebook check's `rtol` or `atol` is negative or not finite.
    case invalidNotebookCheckTolerance(checkID: String, kindLabel: String, tolerance: String)
    /// A notebook check's count field is missing or negative.
    case invalidNotebookCheckCount(checkID: String, kindLabel: String, field: String)
    /// A notebook check's expected CSV is missing or empty.
    case notebookCheckExpectedCSVEmpty(checkID: String, kindLabel: String)
    /// A notebook check's expected CSV does not start with a header row.
    case notebookCheckExpectedCSVMissingHeader(checkID: String, kindLabel: String)
    /// A `cellContains` regex has unbalanced parentheses.
    case cellContainsRegexUnbalanced(checkID: String)
    /// A `cellContains` regex ends with a backslash that escapes nothing.
    case cellContainsRegexDanglingBackslash(checkID: String)
    /// A `cellContains` check has no text to find.
    case cellContainsEmptyText(checkID: String)
    /// A `dataFrameColumns` check lists no columns.
    case dataFrameColumnsEmpty(checkID: String)
    /// A `dataFrameColumns` check lists an empty column name.
    case dataFrameColumnsEmptyEntry(checkID: String)
    /// A `dataFrameColumns` check lists a column name twice under exact
    /// matching.
    case dataFrameColumnsDuplicateNames(checkID: String)
    /// A `seriesEquality` check's expected CSV has more than one column.
    case seriesEqualityCSVHasSeveralColumns(checkID: String)
    /// A `numericArrayClose` check has no expected array.
    case numericArrayCloseEmptyArray(checkID: String)
    /// A `functionExists` check has a negative expected arity.
    case functionExistsNegativeArity(checkID: String)
    /// A `variableExists` check's expected type is blank.
    case variableExistsBlankType(checkID: String)
    /// An `astStructure` check lists no constructs.
    case astStructureNoConstructs(checkID: String)
    /// An `astStructure` import predicate names an invalid module.
    case astStructureInvalidImport(checkID: String, predicate: String)
    /// An `astStructure` check lists an unknown predicate.
    case astStructureUnknownPredicate(checkID: String, predicate: String)
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

        case .notebookCheckFieldMissing(let checkID, let kindLabel, let field):
            return "Notebook check '\(checkID)' (\(kindLabel)): \(field) is required"
        case .notebookCheckFieldNotIdentifier(let checkID, let kindLabel, let field, let value, let language):
            return
                "Notebook check '\(checkID)' (\(kindLabel)): \(field) '\(value)' is not a valid \(identifierKindName(language))"
        case .invalidNotebookCheckTolerance(let checkID, let kindLabel, let tolerance):
            return "Notebook check '\(checkID)' (\(kindLabel)): \(tolerance) must be a non-negative finite number"
        case .invalidNotebookCheckCount(let checkID, let kindLabel, let field):
            return "Notebook check '\(checkID)' (\(kindLabel)): \(field) must be a non-negative integer"
        case .notebookCheckExpectedCSVEmpty(let checkID, let kindLabel):
            return "Notebook check '\(checkID)' (\(kindLabel)): expectedCSV must be a non-empty CSV string"
        case .notebookCheckExpectedCSVMissingHeader(let checkID, let kindLabel):
            return "Notebook check '\(checkID)' (\(kindLabel)): expectedCSV must begin with a header row"
        case .cellContainsRegexUnbalanced(let checkID):
            return "Notebook check '\(checkID)' (cell_contains): regex has unbalanced parentheses"
        case .cellContainsRegexDanglingBackslash(let checkID):
            return "Notebook check '\(checkID)' (cell_contains): regex ends with a dangling backslash"
        case .cellContainsEmptyText(let checkID):
            return "Notebook check '\(checkID)' (cell_contains): containsText must be a non-empty string"
        case .dataFrameColumnsEmpty(let checkID):
            return "Notebook check '\(checkID)' (data_frame_columns): expectedColumns must be a non-empty list"
        case .dataFrameColumnsEmptyEntry(let checkID):
            return "Notebook check '\(checkID)' (data_frame_columns): expectedColumns contains an empty entry"
        case .dataFrameColumnsDuplicateNames(let checkID):
            return
                "Notebook check '\(checkID)' (data_frame_columns): expectedColumns contains duplicate names under exact matching"
        case .seriesEqualityCSVHasSeveralColumns(let checkID):
            return
                "Notebook check '\(checkID)' (series_equality): expectedCSV must have exactly one column (header had a comma)"
        case .numericArrayCloseEmptyArray(let checkID):
            return
                "Notebook check '\(checkID)' (numeric_array_close): expectedArray must be a non-empty list of numbers"
        case .functionExistsNegativeArity(let checkID):
            return "Notebook check '\(checkID)' (function_exists): expectedArity must be non-negative"
        case .variableExistsBlankType(let checkID):
            return
                "Notebook check '\(checkID)' (variable_exists): expectedType must be a non-empty type name when set (e.g. \"int\", \"list\", \"DataFrame\")"
        case .astStructureNoConstructs(let checkID):
            return "Notebook check '\(checkID)' (ast_structure): requiredConstructs must be a non-empty list"
        case .astStructureInvalidImport(let checkID, let predicate):
            return
                "Notebook check '\(checkID)' (ast_structure): import predicate '\(predicate)' has an invalid module name"
        case .astStructureUnknownPredicate(let checkID, let predicate):
            return
                "Notebook check '\(checkID)' (ast_structure): unknown predicate '\(predicate)' — supported: for_loop, while_loop, list_comprehension, lambda, recursion, import:<module>, optional leading `!` for negation"
        }
    }

    var errorDescription: String? { description }
}
