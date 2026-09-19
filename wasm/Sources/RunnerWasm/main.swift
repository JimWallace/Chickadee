import JavaScriptEventLoop

// Bridge Swift Concurrency to the JS microtask loop so the async `executeSuites`
// export can await the JS `run` callback's Promise. This must run before any
// exported async function is called; the exports themselves are declared in
// Bridge.swift with BridgeJS `@JS`.
JavaScriptEventLoop.installGlobalExecutor()
