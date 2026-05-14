import Fluent
import Testing

@testable import chickadee_server

@Suite struct AuthModeResolutionTests {

    // All requested modes resolve to .sso when non-SSO modes are disabled.
    @Test(arguments: [nil, AuthMode.sso, .local, .dual] as [AuthMode?])
    func allModesMapToSSOWhenFlagDisabled(requested: AuthMode?) {
        #expect(resolvedAuthMode(requestedMode: requested, nonSSOModesEnabled: false) == .sso)
    }

    // Non-SSO modes (.local, .dual) are honoured when the flag is enabled.
    @Test(arguments: [AuthMode.local, .dual])
    func nonSSOModesAllowedWhenFlagEnabled(mode: AuthMode) {
        #expect(resolvedAuthMode(requestedMode: mode, nonSSOModesEnabled: true) == mode)
    }
}
