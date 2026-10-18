// APIServer/Services/ActivitySessionStoreError.swift
//
// The failure of `ActivitySessionStore` that no person can act on.

/// A store failure no person can act on.
enum ActivitySessionStoreError: Error, Sendable {
    /// Eight draws in a row hit a taken code, which at 25 to the fifth codes
    /// means something other than chance is wrong.
    case noFreeCode
}
