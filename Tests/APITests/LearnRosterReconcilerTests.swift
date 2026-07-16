import Testing

@testable import APIServer

@Suite struct LearnRosterReconcilerTests {

    private func entry(
        _ org: String?, _ user: String?, userID: String? = nil
    ) -> BrightSpaceClasslistEntry {
        BrightSpaceClasslistEntry(orgDefinedID: org, username: user, userID: userID)
    }

    private func index(_ entries: [BrightSpaceClasslistEntry]) -> BrightSpaceIdentityIndex {
        BrightSpaceIdentityIndex(classlist: entries)
    }

    @Test func indexNormalizesBothFieldsAndDropsBlanks() {
        let ids = index([
            entry("20851234", "JDoe"),
            entry(nil, "ASmith"),
            entry("  ", nil),
            entry("", ""),
        ])
        #expect(ids.contains("20851234"))
        #expect(ids.contains("jdoe"))
        #expect(ids.contains("asmith"))
        #expect(!ids.contains(""))
        #expect(!ids.contains(nil))
    }

    @Test func studentMatchedByStudentIDIsOnLearn() {
        let ids = index([entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["20851234", "jdoe"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func studentWithIDNotInClasslistIsNotOnLearn() {
        let ids = index([entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["99999999", "dropped"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .notOnLearn)
    }

    @Test func studentWithoutIDButMatchingUsernameIsOnLearn() {
        let ids = index([entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["", "JDOE"], hasIdentityKey: false, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func studentWithoutIDAndNoUsernameMatchIsUnverifiable() {
        let ids = index([entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["", "mystery"], hasIdentityKey: false, learnIdentities: ids)
        #expect(status == .unverifiable)
    }

    @Test func pendingUsernameInClasslistIsOnLearn() {
        // Pre-enrollments carry only a username; match against either the
        // classlist username OR its org-defined ID (CSV format varies).
        let ids = index([entry("20851234", "jdoe")])
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["jdoe"], hasIdentityKey: true, learnIdentities: ids) == .onLearn)
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["20851234"], hasIdentityKey: true, learnIdentities: ids) == .onLearn)
    }

    @Test func pendingUsernameNotInClasslistIsNotOnLearn() {
        let ids = index([entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["someonewhodropped"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .notOnLearn)
    }

    @Test func matchingIsCaseAndWhitespaceInsensitive() {
        let ids = index([entry(nil, "JDoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["  jDOE  "], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func emptyClasslistFlagsEveryStudentWithAnID() {
        let ids = index([])
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["20851234", "jdoe"], hasIdentityKey: true, learnIdentities: ids)
                == .notOnLearn)
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["", "jdoe"], hasIdentityKey: false, learnIdentities: ids)
                == .unverifiable)
    }

    // MARK: - D2L UserId resolution (#1117 — the grade-push / section-sync side)

    @Test func d2lUserIDMatchesUsernameFirstThenStudentNumber() {
        let ids = index([
            entry("20851234", "jdoe", userID: "111"),
            entry("20859999", "asmith", userID: "222"),
        ])
        #expect(ids.d2lUserID(username: "JDoe", studentID: nil) == "111")
        #expect(ids.d2lUserID(username: nil, studentID: " 20859999 ") == "222")
        // Username wins when both would match different rows.
        #expect(ids.d2lUserID(username: "asmith", studentID: "20851234") == "222")
        #expect(ids.d2lUserID(username: "nobody", studentID: "00000000") == nil)
    }

    @Test func d2lUserIDIgnoresEntriesWithoutAUserID() {
        // A classlist row with no D2L UserId still counts for membership
        // (contains) but can never resolve an id.
        let ids = index([entry("20851234", "jdoe", userID: nil)])
        #expect(ids.contains("jdoe"))
        #expect(ids.d2lUserID(username: "jdoe", studentID: "20851234") == nil)
    }

    @Test func whitespaceAffectedClasslistEntryStillResolves() {
        // The drift #1117 fixed: section sync lowercased but didn't trim, so a
        // classlist username with stray whitespace matched for grade push but
        // silently failed section sync. One index, one normalization.
        let ids = index([entry(nil, "  JDoe \n", userID: "333")])
        #expect(ids.d2lUserID(username: "jdoe", studentID: nil) == "333")
        #expect(ids.contains("jdoe"))
    }
}
