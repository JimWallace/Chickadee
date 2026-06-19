// Tests/APITests/JupyterLiteConfigTests.swift
//
// Regression guard for the JupyterLite bundle config (`Public/jupyterlite/
// jupyter-lite.json`).  Asserts the service-worker-manager plugin is ENABLED
// (i.e. NOT in disabledExtensions).
//
// History — this guard was INVERTED:
//
//   * v0.4.150 (PR #467) DISABLED the service-worker-manager plugin because
//     students saw 404s on `/jupyterlite/api/drive` and the kernel stuck in
//     "Unknown".  Root cause was a never-fully-understood SW registration/
//     controller race.  Disabling forced `mountDrive=false` and avoided it.
//   * BUT disabling the SW also removed the kernel's ONLY synchronous-execution
//     mechanism (the SW intercepts `/api/drive` AND `/api/stdin/` and broadcasts
//     to the kernel).  With no SW and no SharedArrayBuffer, a synchronous kernel
//     op (`input()`) hard-freezes the page — the "Page Unresponsive" freeze.
//     v0.4.150's own changelog flagged this: "no stdin … input() in cells will
//     hang."
//   * Re-enabling the SW restores that sync mechanism and fixes the freeze. The
//     vended SW already does `self.skipWaiting()` + `self.clients.claim()`
//     (see Public/jupyterlite/service-worker.js), the standard lifecycle that
//     addresses the original controller race.
//
// ⚠️ Re-enabling reverses a guarded decision and reintroduces the risk of the
// "Kernel Unknown" race on devices where the SW fails to control the page.
// This MUST be browser-verified (Chrome + Safari + a managed device) before it
// ships — CI cannot test it.  If Kernel Unknown recurs, the next step is a
// kernel-wheel patch that gates `mountDrive` on the SW actually controlling the
// page (graceful degradation), not re-disabling the SW.

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

    @Test func sourceConfigEnablesServiceWorkerManager() throws {
        let url = URL(fileURLWithPath: sourceConfigPath)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "source jupyter-lite.json missing or malformed at \(sourceConfigPath)"
        )
        let cfg = try #require(root["jupyter-config-data"] as? [String: Any])

        let disabled = cfg["disabledExtensions"] as? [String] ?? []
        let sourceMsg: Comment = """
            Expected source JupyterLite config (\(sourceConfigPath)) to ENABLE the \
            service-worker-manager plugin (not in disabledExtensions) so the kernel \
            regains its SW-based stdin/Drive sync and the input()-freeze is fixed. \
            Got disabledExtensions=\(disabled). Do not re-disable without restoring \
            another sync mechanism — disabling alone reintroduces the freeze.
            """
        #expect(!disabled.contains(Self.serviceWorkerManager), sourceMsg)
    }

    @Test func bundleEnablesServiceWorkerManager() throws {
        let url = URL(fileURLWithPath: configPath)
        let data = try Data(contentsOf: url)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "jupyter-lite.json missing or malformed at \(configPath)"
        )
        let cfg = try #require(root["jupyter-config-data"] as? [String: Any])

        let disabled = cfg["disabledExtensions"] as? [String] ?? []
        let bundleMsg: Comment = """
            Expected built JupyterLite bundle to ENABLE the service-worker-manager \
            plugin (not in disabledExtensions). Got disabledExtensions=\(disabled). \
            Remove it from Tools/jupyterlite/jupyter-lite.json and re-run \
            scripts/build-jupyterlite.sh (or sync the served config).
            """
        #expect(!disabled.contains(Self.serviceWorkerManager), bundleMsg)
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
