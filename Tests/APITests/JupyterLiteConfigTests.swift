// Tests/APITests/JupyterLiteConfigTests.swift
//
// Regression guard for the JupyterLite bundle config (`Public/jupyterlite/
// jupyter-lite.json`).  Asserts the disabledExtensions entries we rely on
// are present — currently:
//
//   @jupyterlite/application-extension:service-worker-manager
//
// Background: in JupyterLite 0.7.x the pyodide-kernel auto-mounts the
// JupyterLite Drive whenever the service-worker-manager plugin reports
// `enabled` (or the page is cross-origin isolated).  When mounted, the
// kernel POSTs to `/api/drive` expecting the service worker to intercept
// and broadcast the call to the in-browser drive plugin.  On Chickadee
// the SW interception was inconsistent — students were seeing 404s on
// `/jupyterlite/api/drive` and the kernel ending up in "Unknown" state
// (PR #467 → v0.4.149 then v0.4.150).  Disabling the SW manager forces
// `mountDrive=false` in the kernel and avoids the entire failure mode.
// We don't rely on the JupyterLite Drive for persistence — Chickadee
// has its own server-side notebook snapshot mechanism.

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
            Expected source JupyterLite config (\(sourceConfigPath)) to disable the \
            service-worker-manager plugin so pyodide-kernel sets mountDrive=false \
            after the next rebuild. Got disabledExtensions=\(disabled). \
            Re-add the entry; do not remove without checking that pyodide-kernel \
            no longer auto-mounts the Drive (the failure mode caught in PR #467 / v0.4.150).
            """
        #expect(
            disabled.contains("@jupyterlite/application-extension:service-worker-manager"),
            sourceMsg
        )
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
            Expected built JupyterLite bundle to disable the service-worker-manager \
            plugin so pyodide-kernel sets mountDrive=false. Got disabledExtensions=\(disabled). \
            Add it to Tools/jupyterlite/jupyter-lite.json and re-run scripts/build-jupyterlite.sh.
            """
        #expect(
            disabled.contains("@jupyterlite/application-extension:service-worker-manager"),
            bundleMsg
        )
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
