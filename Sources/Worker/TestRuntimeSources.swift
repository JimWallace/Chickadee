// Worker/TestRuntimeSources.swift
//
// Which runtime helper files each language's generated tests expect to find
// beside them in the grading workspace.
//
// THE SOURCES ARE NOT HERE ANY MORE. This file used to carry 2,223 lines of
// Swift string literals that mirrored `Tools/runner-support/*` by hand, kept
// honest by a drift test that compared the two copies line by line. The
// canonical files are now compiled straight into the binary by
// `Plugins/EmbedRunnerSupport`, which supplies
// `canonicalRuntimeHelperSources`. There is no second copy, so there is nothing
// for a drift test to catch — and the helper a student's test loads is, byte
// for byte, the file a maintainer edits.
//
// (One consequence worth knowing: the old literals dropped some of the
// canonical files' comments, so the injected helpers now carry a few more
// comment lines than before. Nothing reads them — the runner writes the file
// and hands it to an interpreter — and the executable code is unchanged, which
// is all the drift test ever asserted.)
//
// WHAT STAYS HAND-WRITTEN, AND WHY. The switch below. It is the compile-forced
// worklist that makes a new language impossible to forget, and it is the only
// place that names a filename. The runner used to install these through five
// separate `write<Language>RuntimeHelper` functions called from a hand-written
// list of five, under a comment reading "one per language, unconditionally" —
// true when written and silently false the moment a sixth language existed.
// Racket shipped with a canonical `test_runtime.rkt`, no embed, no write call
// and no test, so every generated Racket test's `(require "test_runtime.rkt")`
// had nothing to find. Nothing failed; the list was simply one shorter than
// `allCases`. Generating the switch too would hand that failure mode straight
// back.

import Core
import Foundation

/// The runtime helper files a language's generated tests expect to find beside
/// them, keyed by the filename written into the grading workspace.
///
/// EXHAUSTIVE ON PURPOSE — see the note above. A dictionary rather than one
/// filename plus one source because Python needs two files: `sitecustomize.py`
/// is loaded by the interpreter itself, not by the test, and it is a runtime
/// helper on exactly the same terms.
func runtimeHelperFiles(for language: AssignmentLanguage) -> [String: String] {
    switch language {
    case .python:
        return canonicalSources("test_runtime.py", "sitecustomize.py")
    case .r:
        return canonicalSources("test_runtime.R")
    case .lua:
        return canonicalSources("test_runtime.lua")
    case .octave:
        return canonicalSources("test_runtime.m")
    case .cpp:
        return canonicalSources("test_runtime.hpp")
    case .racket:
        return canonicalSources("test_runtime.rkt")
    case .java:
        return canonicalSources("test_runtime.java")
    }
}

/// The `test_runtime.*` source for a language — the one file its generated
/// tests load explicitly, as distinct from Python's interpreter-loaded
/// `sitecustomize.py`.
///
/// Derived from the switch above rather than being a second per-language table,
/// so it cannot name a file the runner does not actually write.
///
/// Non-optional: every arm of that switch names exactly one `test_runtime.*`,
/// and an arm that does not is a coding error rather than a state a caller
/// should branch on.
func testRuntimeSource(for language: AssignmentLanguage) -> String {
    guard
        let source = runtimeHelperFiles(for: language)
            .first(where: { $0.key.hasPrefix("test_runtime.") })?.value
    else {
        preconditionFailure(
            "\(language) names no test_runtime.* file in runtimeHelperFiles(for:)")
    }
    return source
}

/// Looks up canonical sources by filename, trapping on one that the plugin did
/// not embed.
///
/// A trap rather than a silent empty string: a missing helper means every
/// generated test in that language fails to load its runtime, and the honest
/// moment to say so is at the point the runner tries to install it, not three
/// layers down in a student's exit code 2. `RuntimeHelperCoverageTests` reaches
/// this first, so the trap is a backstop rather than the guard.
private func canonicalSources(_ filenames: String...) -> [String: String] {
    var files: [String: String] = [:]
    for filename in filenames {
        guard let source = canonicalRuntimeHelperSources[filename] else {
            preconditionFailure(
                """
                Tools/runner-support/\(filename) was not embedded. Plugins/EmbedRunnerSupport \
                takes every `test_runtime.*` plus `sitecustomize.py` in that directory; if the \
                file exists under another name, the switch in TestRuntimeSources.swift is naming \
                the wrong one.
                """)
        }
        files[filename] = source
    }
    return files
}

/// Every language's runtime helpers, in one map. Duplicate filenames across
/// languages would silently drop one, so this traps rather than merging — the
/// inputs-filename uniqueness invariant applies here for the same reason.
func allRuntimeHelperFiles() -> [String: String] {
    var files: [String: String] = [:]
    for language in AssignmentLanguage.allCases {
        for (name, source) in runtimeHelperFiles(for: language) {
            precondition(
                files[name] == nil,
                "two languages both claim the runtime helper filename \(name)")
            files[name] = source
        }
    }
    return files
}
