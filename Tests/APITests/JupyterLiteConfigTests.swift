// Tests/APITests/JupyterLiteConfigTests.swift
//
// Regression guard for the JupyterLite bundle config (`Public/jupyterlite/
// jupyter-lite.json`).  Asserts the service-worker-manager plugin is DISABLED
// (i.e. listed in disabledExtensions).
//
// History — this guard has flipped twice, tracking the kernel's sync mechanism:
//
//   * v0.4.150 (PR #467) DISABLED the SW (kernel stuck "Unknown" from an SW
//     registration/controller race) — but that removed the kernel's only
//     synchronous-execution path, so `input()` hard-froze the page (#959).
//   * v0.4.467 RE-ENABLED the SW to restore sync and kill the freeze — at the
//     cost of reintroducing the SW-control "Kernel Unknown" race on devices
//     where the SW failed to control the page in time.
//   * Now: cross-origin isolation is unconditional, so the kernel uses
//     `SharedArrayBuffer` for synchronous stdin/Drive and no longer needs the
//     SW at all.  The SW is therefore DISABLED again — but this time there is no
//     freeze (SAB carries sync) AND no control race (no SW to race).  This is
//     the deterministic end state: one sync path, no fallback.
//
// This is browser-verified by the editor-smoke harness
// (`Tools/editor-smoke-test`): the selftest boots the editor with no SW and
// asserts the kernel + `input()` work over SAB, and the authenticated
// notebook-page e2e loads the student's notebook from the Drive and grades a
// real submission — both under Chromium AND WebKit (Safari engine).  If you ever
// re-ENABLE the SW, restore the old "must be enabled" assertion and rationale.

import Foundation
import Testing

@Suite struct JupyterLiteConfigTests {

    /// `Public/jupyterlite/jupyter-lite.json` relative to the repo root.
    /// `swift test` is run from the package root so the relative path
    /// resolves directly.
    private let configPath = "Public/jupyterlite/jupyter-lite.json"

    /// Source config consumed by `scripts/build-jupyterlite.sh`.  Catches
    /// regressions on the source-of-truth before they propagate into the
    /// built bundle on the next rebuild.
    private let sourceConfigPath = "Tools/jupyterlite/jupyter-lite.json"

    private static let serviceWorkerManager =
        "@jupyterlite/application-extension:service-worker-manager"

    @Test func sourceConfigDisablesServiceWorkerManager() throws {
        let url = URL(fileURLWithPath: sourceConfigPath)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "source jupyter-lite.json missing or malformed at \(sourceConfigPath)"
        )
        let cfg = try #require(root["jupyter-config-data"] as? [String: Any])

        let disabled = cfg["disabledExtensions"] as? [String] ?? []
        let sourceMsg: Comment = """
            Expected source JupyterLite config (\(sourceConfigPath)) to DISABLE the \
            service-worker-manager plugin (listed in disabledExtensions): the kernel \
            now syncs stdin/Drive over SharedArrayBuffer (cross-origin isolation), so \
            the SW is redundant. Got disabledExtensions=\(disabled). Do not re-enable \
            without reverting the editor to the SW sync path — see the file header.
            """
        #expect(disabled.contains(Self.serviceWorkerManager), sourceMsg)
    }

    @Test func bundleDisablesServiceWorkerManager() throws {
        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jupyter-lite.json missing or malformed at \(configPath)"
        )
        let cfg = try #require(root["jupyter-config-data"] as? [String: Any])

        let disabled = cfg["disabledExtensions"] as? [String] ?? []
        let bundleMsg: Comment = """
            Expected built JupyterLite bundle to DISABLE the service-worker-manager \
            plugin (listed in disabledExtensions); the kernel uses SharedArrayBuffer \
            now. Got disabledExtensions=\(disabled). Add it to \
            Tools/jupyterlite/jupyter-lite.json and sync the served config.
            """
        #expect(disabled.contains(Self.serviceWorkerManager), bundleMsg)
    }

    @Test func bundleAppVersionMatchesRequirementsPin() throws {
        // Source of truth: Tools/jupyterlite/requirements.txt.
        // If JupyterLite is bumped, the appVersion label in the source
        // config (Tools/jupyterlite/jupyter-lite.json) should be bumped
        // to match.  The built bundle preserves whatever the source
        // says, so this catches stale labels after a version bump.
        let reqData = try Data(contentsOf: URL(fileURLWithPath: "Tools/jupyterlite/requirements.txt"))
        let reqText = String(data: reqData, encoding: .utf8) ?? ""
        let pin = try #require(
            reqText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first { $0.hasPrefix("jupyterlite==") }
                .map { String($0.replacingOccurrences(of: "jupyterlite==", with: "")) },
            "Could not find jupyterlite==X.Y.Z pin in Tools/jupyterlite/requirements.txt"
        )

        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jupyter-lite.json missing or malformed at \(configPath)"
        )
        let cfg = try #require(root["jupyter-config-data"] as? [String: Any])
        let appVersion = try #require(cfg["appVersion"] as? String)

        let versionMsg: Comment = """
            appVersion label '\(appVersion)' in the built bundle does not start with \
            the pinned JupyterLite version '\(pin)' from requirements.txt. Update \
            Tools/jupyterlite/jupyter-lite.json's appVersion to match (e.g. '\(pin)-chickadee.N').
            """
        #expect(
            appVersion.hasPrefix(pin),
            versionMsg
        )
    }
}
