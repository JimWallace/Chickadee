### Changed

- **The wasm bridge package builds in Swift 6 language mode**, the same mode
  as the main package. It carried `swiftLanguageModes: [.v5]` from
  JavaScriptKit's Embedded example, and while it was hand-marshalled it needed
  to (non-`Sendable` `JSObject`s behind an `async` protocol); with BridgeJS the
  executor holds the plugin's typed closures inside one call, and the package
  builds with zero strict-concurrency diagnostics on the 6.4 Embedded SDK.
