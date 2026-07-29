// Tests/WorkerTests/WedgeWatchdogTests.swift

import Foundation
import Testing

@Suite struct WedgeWatchdogTests {

    /// The dump is the evidence path for a wedged process (issue #1233): it
    /// must never crash or throw, and it must not depend on the cooperative
    /// pool being healthy. This exercises the /proc walk end-to-end; the
    /// output itself goes to stderr, where CI preserves it.
    @Test func threadStateDumpDoesNotCrash() {
        WedgeWatchdog.dumpThreadStates(reason: "WedgeWatchdogTests smoke test — not a real wedge")
    }

    /// Liveness reporting must be callable from anywhere, repeatedly, without
    /// arming anything visible to the tests themselves.
    @Test func activityReportingIsReentrant() async {
        for _ in 0..<100 {
            WedgeWatchdog.noteActivity()
        }
        let value = await WedgeWatchdog.track { 42 }
        #expect(value == 42)
    }
}
