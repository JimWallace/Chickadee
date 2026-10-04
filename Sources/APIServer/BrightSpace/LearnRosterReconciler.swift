// APIServer/Routes/Web/LearnRosterReconciler.swift
//
// Pure roster-vs-LEARN classification.  Given the LEARN classlist identities
// and a Chickadee roster entry, decides whether the entry is still registered
// on LEARN, has dropped, or can't be matched.  Kept free of Fluent / Request
// so it can be unit-tested without a server or live D2L credentials — the live
// classlist fetch lives on `BrightSpaceAPIClient.fetchClasslist`.

import Foundation

enum LearnRosterStatus: Equatable {
    case onLearn
    case notOnLearn
    /// No authoritative identity key to match on (e.g. an enrolled user with
    /// no student ID whose username also didn't match) — never flagged for
    /// removal, only surfaced so the instructor knows it couldn't be checked.
    case unverifiable
}

enum LearnRosterReconciler {
    /// Classifies one roster entry.  `candidateKeys` are the identifiers this
    /// entry could be known by on LEARN (student ID and/or username).
    /// `hasIdentityKey` is true when the entry carries a key we trust to be
    /// authoritative (a student ID, or a pre-enrollment username) — when
    /// false, an unmatched entry is `.unverifiable` rather than `.notOnLearn`,
    /// so an account we simply couldn't look up is never flagged for removal.
    ///
    /// Membership + normalization come from the shared
    /// `BrightSpaceIdentityIndex` (#1117), so the reconciler can never drift
    /// from the grade-push / section-sync classlist matching.
    static func classify(
        candidateKeys: [String?],
        hasIdentityKey: Bool,
        learnIdentities: BrightSpaceIdentityIndex
    ) -> LearnRosterStatus {
        if candidateKeys.contains(where: { learnIdentities.contains($0) }) { return .onLearn }
        return hasIdentityKey ? .notOnLearn : .unverifiable
    }
}
