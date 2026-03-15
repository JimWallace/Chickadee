// APIServer/Utilities/ManifestValidation.swift
//
// Validates the dependency graph in a TestProperties manifest.

import Core
import Vapor

/// Validates the `dependsOn` references and dependency graph in a manifest.
///
/// Throws an `Abort(.unprocessableEntity)` if:
/// - Any `dependsOn` entry names a script that does not exist in `testSuites`.
/// - The dependency graph contains a cycle.
func validateManifestDependencies(_ manifest: TestProperties) throws {
    let allScripts = Set(manifest.testSuites.map(\.script))

    // 1. Reference check — every name in dependsOn must be a known script.
    for entry in manifest.testSuites {
        for dep in entry.dependsOn {
            guard allScripts.contains(dep) else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Manifest dependency error: '\(entry.script)' depends on '\(dep)', which is not listed in testSuites"
                )
            }
            guard dep != entry.script else {
                throw Abort(
                    .unprocessableEntity,
                    reason: "Manifest dependency error: '\(entry.script)' cannot depend on itself"
                )
            }
        }
    }

    // 2. Cycle detection via DFS (Kahn-style).
    //    Build adjacency list: script → scripts that depend on it.
    var inDegree: [String: Int] = [:]
    var dependents: [String: [String]] = [:]  // prerequisite → [scripts that need it]
    for entry in manifest.testSuites {
        inDegree[entry.script, default: 0] += 0  // ensure every node is present
        for dep in entry.dependsOn {
            dependents[dep, default: []].append(entry.script)
            inDegree[entry.script, default: 0] += 1
        }
    }

    var queue = inDegree.filter { $0.value == 0 }.map(\.key)
    var processed = 0
    while !queue.isEmpty {
        let node = queue.removeLast()
        processed += 1
        for dependent in dependents[node, default: []] {
            inDegree[dependent, default: 0] -= 1
            if inDegree[dependent, default: 0] == 0 {
                queue.append(dependent)
            }
        }
    }

    guard processed == manifest.testSuites.count else {
        throw Abort(
            .unprocessableEntity,
            reason: "Manifest dependency error: dependency graph contains a cycle"
        )
    }
}
