// APIServer/Utilities/TestSpecRendering.swift
//
// The single dispatch point that turns any `GeneratedTestSpec`
// (`PatternFamily`, `NotebookCheck`) into rendered test files.  Today it
// forwards verbatim to the per-generator renderers; the value is that
// every caller in the save path now goes through ONE entry point with a
// shared context object, so the upcoming `=`-expression work has exactly
// one place to thread per-student evaluation context instead of forking
// the two renderers independently.

import Core
import Foundation

/// What a generated-test spec needs from the surrounding assignment in
/// order to render.  Today that's the variable scope a generated test
/// sees (assignment-global + the spec's home-section variables).  This is
/// the seam the procedural (`=`-expression) phase extends — e.g. with the
/// support-file directory and the per-student seed binding.
struct TestRenderContext {
    var sectionVariables: [FamilyVariable] = []
    var globalVariables: [FamilyVariable] = []
}

/// Uniform rendered output for any spec.  A `PatternFamily` yields one
/// `GeneratedScript` per enabled case and no sidecars; a `NotebookCheck`
/// yields exactly one script plus zero or more sidecar files (e.g.
/// `_expected_<id>.csv` for `.dataFrameEquality`).
struct RenderedTestBundle: Equatable {
    var scripts: [GeneratedScript]
    var sidecars: [String: String]
}

/// Renders any spec to scripts + sidecars.  Pure: identical input yields
/// byte-identical output, so it preserves the determinism the runner
/// cache relies on.
func renderTestSpec(_ spec: any GeneratedTestSpec, context: TestRenderContext) -> RenderedTestBundle {
    switch spec {
    case let family as PatternFamily:
        let scripts = renderPatternFamily(
            family,
            sectionVariables: context.sectionVariables,
            globalVariables: context.globalVariables)
        return RenderedTestBundle(scripts: scripts, sidecars: [:])
    case let check as NotebookCheck:
        let bundle = renderNotebookCheck(check)
        return RenderedTestBundle(scripts: [bundle.script], sidecars: bundle.sidecars)
    default:
        return RenderedTestBundle(scripts: [], sidecars: [:])
    }
}

/// Every filename a spec *would* produce if all of its cases were enabled
/// (scripts + sidecars).  Used by the save path's old/new diff so stale
/// files — including previously-disabled cases and check sidecars — get
/// cleaned out of the test setup zip.
func allGeneratedFilenames(_ spec: any GeneratedTestSpec) -> [String] {
    switch spec {
    case let family as PatternFamily:
        return patternFamilyAllGeneratedFilenames(family)
    case let check as NotebookCheck:
        return notebookCheckAllGeneratedFilenames(check)
    default:
        return []
    }
}
