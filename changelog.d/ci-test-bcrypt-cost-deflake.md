### Changed

- **De-flaked the nightly clean-build & coverage run.** Test fixtures now hash
  passwords at the minimum bcrypt cost (4) instead of the production default
  (12) via a shared `testPasswordHash()` helper. Running cost-12 hash+verify for
  every login across the parallel suite saturated the 2-core CI runner; under the
  coverage build's slowdown that CPU starvation intermittently flaked
  auth-dependent tests (303/401 redirects, ~80 s stalls). The app's configured
  hasher is unchanged, so `AuthProvider`'s account-enumeration timing-equalizer
  still runs at production cost.
