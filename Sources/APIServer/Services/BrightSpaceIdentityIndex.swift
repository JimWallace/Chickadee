// APIServer/Services/BrightSpaceIdentityIndex.swift
//
// The ONE reduction of a LEARN classlist into matchable identities (#1117).
// Grade sync, section sync, and the roster reconciler all resolve Chickadee
// users against the classlist; before this they each built their own map with
// divergent normalization (section sync lowercased but didn't trim, so a
// classlist username with stray whitespace matched for grade push but
// silently failed section sync) and their own username-vs-student-number
// precedence. One index, one `normalize`, one precedence.

import Foundation

/// A LEARN classlist reduced to an identity → D2L UserId index plus the set
/// of matchable identity keys. Identity keys are the classlist's usernames
/// and OrgDefinedIds (student numbers), normalized by trimming whitespace and
/// lowercasing — the single normalization every consumer shares.
struct BrightSpaceIdentityIndex: Sendable {
    private let d2lUserIDByIdentity: [String: String]
    /// Every matchable identity, including entries whose classlist row carries
    /// no D2L UserId — the roster reconciler's membership test must still see
    /// those students as "on LEARN" even when no id is resolvable.
    private let identities: Set<String>

    init(classlist: [BrightSpaceClasslistEntry]) {
        var map: [String: String] = [:]
        var all: Set<String> = []
        for entry in classlist {
            let keys = [entry.username, entry.orgDefinedID]
                .compactMap { $0.map(Self.normalize) }
                .filter { !$0.isEmpty }
            all.formUnion(keys)
            guard let userID = entry.userID, !userID.isEmpty else { continue }
            for key in keys { map[key] = userID }
        }
        self.d2lUserIDByIdentity = map
        self.identities = all
    }

    /// The shared identity normalization: trim + lowercase.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Resolves a Chickadee user's D2L UserId, matching by **username first,
    /// student number second** — the username is the identity Chickadee always
    /// has (SSO or local) and equals the LEARN username at UW, so resolution
    /// works without a student-number claim. The one precedence, shared by
    /// grade push and section sync.
    func d2lUserID(username: String?, studentID: String?) -> String? {
        for identity in [username, studentID] {
            guard let key = identity.map(Self.normalize), !key.isEmpty else { continue }
            if let resolved = d2lUserIDByIdentity[key] { return resolved }
        }
        return nil
    }

    /// True when `identity` (any of a user's candidate keys) appears on the
    /// classlist — the roster reconciler's membership test.
    func contains(_ identity: String?) -> Bool {
        guard let key = identity.map(Self.normalize), !key.isEmpty else { return false }
        return identities.contains(key)
    }
}
