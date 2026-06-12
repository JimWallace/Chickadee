import Testing

@testable import APIServer

@Suite struct LearnRosterReconcilerTests {

    private func entry(_ org: String?, _ user: String?) -> BrightSpaceClasslistEntry {
        BrightSpaceClasslistEntry(orgDefinedID: org, username: user)
    }

    @Test func identitySetLowercasesBothFieldsAndDropsBlanks() {
        let ids = LearnRosterReconciler.identitySet(from: [
            entry("20851234", "JDoe"),
            entry(nil, "ASmith"),
            entry("  ", nil),
            entry("", ""),
        ])
        #expect(ids.contains("20851234"))
        #expect(ids.contains("jdoe"))
        #expect(ids.contains("asmith"))
        #expect(!ids.contains(""))
        #expect(ids.count == 3)
    }

    @Test func studentMatchedByStudentIDIsOnLearn() {
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["20851234", "jdoe"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func studentWithIDNotInClasslistIsNotOnLearn() {
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["99999999", "dropped"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .notOnLearn)
    }

    @Test func studentWithoutIDButMatchingUsernameIsOnLearn() {
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["", "JDOE"], hasIdentityKey: false, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func studentWithoutIDAndNoUsernameMatchIsUnverifiable() {
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["", "mystery"], hasIdentityKey: false, learnIdentities: ids)
        #expect(status == .unverifiable)
    }

    @Test func pendingUsernameInClasslistIsOnLearn() {
        // Pre-enrollments carry only a username; match against either the
        // classlist username OR its org-defined ID (CSV format varies).
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["jdoe"], hasIdentityKey: true, learnIdentities: ids) == .onLearn)
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["20851234"], hasIdentityKey: true, learnIdentities: ids) == .onLearn)
    }

    @Test func pendingUsernameNotInClasslistIsNotOnLearn() {
        let ids = LearnRosterReconciler.identitySet(from: [entry("20851234", "jdoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["someonewhodropped"], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .notOnLearn)
    }

    @Test func matchingIsCaseAndWhitespaceInsensitive() {
        let ids = LearnRosterReconciler.identitySet(from: [entry(nil, "JDoe")])
        let status = LearnRosterReconciler.classify(
            candidateKeys: ["  jDOE  "], hasIdentityKey: true, learnIdentities: ids)
        #expect(status == .onLearn)
    }

    @Test func emptyClasslistFlagsEveryStudentWithAnID() {
        let ids = LearnRosterReconciler.identitySet(from: [])
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["20851234", "jdoe"], hasIdentityKey: true, learnIdentities: ids)
                == .notOnLearn)
        #expect(
            LearnRosterReconciler.classify(
                candidateKeys: ["", "jdoe"], hasIdentityKey: false, learnIdentities: ids)
                == .unverifiable)
    }
}
