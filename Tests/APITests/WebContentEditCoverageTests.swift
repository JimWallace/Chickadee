// Architectural guard for the web side of the post-edit effects (#2259, item 1).
//
// The web twin of `MCPContentEditCoverageTests`. Every web handler that resolves
// an assignment and its setup through `loadAssignmentAndSetupForWrite` must be
// classified:
// either its edit can change what the suite grades, and it calls
// `applyContentEditEffects` (re-grade and re-validate on the server), or it is
// listed below with the reason it does not. A new write handler that is in no
// list fails here, so "can a new web edit forget to re-validate?" is a failing
// test and not a silent gap. A support-file delete was that gap: it relied on
// the page to send a follow-up request, and the page did not.
//
// Scope: the scan covers that one seam. `loadAssignmentForWrite` resolves no
// setup, so its handlers cannot change what the suite grades. The notebook
// save (`WebRoutes+NotebookSave.swift`) reaches its setup by id and is outside
// the scan; it re-validates by its own call.

import ChickadeeTestSupport
import Foundation
import Testing

@testable import APIServer

@Suite struct WebContentEditCoverageTests {
    private static var webRoutesDirectory: URL {
        repositoryRoot.appendingPathComponent("Sources/APIServer/Routes/Web")
    }

    /// Handlers whose edit can change what the suite grades. Each must call
    /// `applyContentEditEffects`.
    private static let contentEditHandlers: Set<String> = [
        "putSuite",
        "updateScript",
        "createScript",
        "deleteScript",
    ]

    /// Handlers that manage the steps after their edit themselves. Adding a
    /// handler here is a policy decision; say why.
    private static let selfManagedHandlers: Set<String> = [
        // The full Save button: it closes the assignment and enqueues a
        // validation run that carries the solution it has just saved.
        "saveEditedAssignment"
    ]

    /// Handlers that resolve for write but whose edit cannot change what the
    /// suite grades. Each mirrors an MCP tool that `MCPContentEditCoverageTests`
    /// lists as non-closing, or changes no assignment content at all.
    private static let nonGradingHandlers: Set<String> = [
        // A grading-environment setting, enforced at run time.
        "putTimeLimit",
        // Dataset marks change delivery, not the graded suite.
        "putDatasets",
        // Display-only awards.
        "putAchievements",
        // Shared inputs re-inline in place; mirrors `update_global_inputs`.
        "putGlobalVariables",
        // Suite-section CRUD: grouping and naming only.
        "createSuiteSection",
        "renameSuiteSection",
        "deleteSuiteSection",
        "reorderSuiteSections",
        // Class-activity settings and tournaments: how results are ranked and
        // shown, not what the suite grades.
        "saveActivityLeaderboardSetting",
        "saveActivityOpponentFile",
        "saveActivityWindow",
        "runTournament",
        // Re-grades on request; it is the effect, not an edit.
        "retestAllSubmissions",
        // Computes a value for the editor and writes nothing.
        "computeExpectedValue",
        // Scaffolds a draft solution in the author's working copy.
        "createSolutionFromAssignment",
        // The copy lands closed and unvalidated; mirrors `clone_assignment`.
        "cloneAssignment",
        // Section inputs re-inline in place; mirrors `update_section_variables`.
        "updateSuiteSectionVariables",
    ]

    /// Every handler that calls the write seam, mapped to its source body.
    ///
    /// A handler is a `func` at member indent, with or without modifiers. Its
    /// body runs to the next member `func` or the next top-level line, which is
    /// how each route file in this directory is laid out. Comment lines are
    /// dropped, so a call that is only mentioned in a comment does not count.
    private static func writeHandlers() throws -> [String: String] {
        let files = try FileManager.default
            .contentsOfDirectory(at: webRoutesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var handlers: [String: String] = [:]
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let starts = lines.indices.filter { isMemberFunction(lines[$0]) }
            let topLevel = lines.indices.filter { index in
                guard let first = lines[index].first else { return false }
                return first != " " && first != "}"
            }
            for start in starts {
                let end =
                    (starts + topLevel).filter { $0 > start }.min() ?? lines.count
                let body = lines[start..<end].joined(separator: "\n")
                guard body.contains("loadAssignmentAndSetupForWrite(") else { continue }
                guard let range = lines[start].range(of: "func ") else { continue }
                let signature = lines[start][range.upperBound...]
                let name = String(signature.prefix { $0 != "(" && $0 != "<" })
                handlers[name] = body
            }
        }
        return handlers
    }

    /// Whether `line` declares a member function: four spaces of indent, then
    /// optional modifiers such as `private` or `@Sendable`, then `func`.
    private static func isMemberFunction(_ line: String) -> Bool {
        guard line.hasPrefix("    "), !line.hasPrefix("     ") else { return false }
        let words = line.dropFirst(4).split(separator: " ")
        guard let funcIndex = words.firstIndex(of: "func") else { return false }
        let modifiers = words[..<funcIndex]
        return modifiers.allSatisfy { word in
            word.hasPrefix("@") || Self.modifiers.contains(String(word))
        }
    }

    private static let modifiers: Set<String> = [
        "private", "fileprivate", "internal", "public", "static", "nonisolated", "mutating",
    ]

    @Test func everyWebWriteHandlerIsClassified() throws {
        let handlers = try Self.writeHandlers()
        #expect(!handlers.isEmpty)

        for (name, body) in handlers {
            let callsEffects = body.contains("applyContentEditEffects(")
            if Self.contentEditHandlers.contains(name) {
                #expect(
                    callsEffects,
                    "\(name) is classified as a content edit but does not call applyContentEditEffects. Its edit would leave the assignment with a stale validation."
                )
            } else if Self.selfManagedHandlers.contains(name) {
                continue
            } else {
                #expect(
                    Self.nonGradingHandlers.contains(name),
                    """
                    \(name) resolves an assignment for write but is not classified for the \
                    post-edit effects (#2259). If its edit can change what the suite grades, \
                    call applyContentEditEffects and add it to contentEditHandlers. If not, \
                    add it to nonGradingHandlers with a one-line reason.
                    """)
                #expect(
                    !callsEffects,
                    "\(name) calls applyContentEditEffects but is classified as non-grading. Move it to contentEditHandlers."
                )
            }
        }
    }

    /// A name in a list that matches no handler is a stale entry, and a stale
    /// entry hides a renamed handler from the check above.
    @Test func everyClassifiedHandlerExists() throws {
        let handlers = Set(try Self.writeHandlers().keys)
        let classified = Self.contentEditHandlers
            .union(Self.selfManagedHandlers)
            .union(Self.nonGradingHandlers)
        #expect(classified.subtracting(handlers).isEmpty, "Stale: \(classified.subtracting(handlers).sorted())")
    }
}
