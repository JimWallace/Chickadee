// Tests/CoreTests/CourseRoleOrderingTests.swift
//
// `CourseRole: Comparable` is the whole basis of authority in this codebase.
// Every `requireCourseRole(atLeast:)` gate and every `evaluateCourseWrite` call
// resolves to one `<` against a rank, so flipping that comparison does not
// weaken permissions in one place — it inverts them everywhere at once, letting
// a student do what only an instructor may and locking instructors out of their
// own courses.
//
// The 2026-08-19 sweep (run 32265903112) reported the flip as a survivor. The
// full suite does kill it — dozens of APITests depend on the gates — but the
// sweep skips APITests, and a Core type whose ordering is asserted only by an
// APIServer route test is a Core invariant nothing local pins. The relation is
// three lines of Core; its assertions belong beside it.

import Foundation
import Testing

@testable import Core

@Suite struct CourseRoleOrderingTests {

    /// The ordering, stated as the ladder it is meant to be.
    @Test func rolesAscendFromStudentToInstructor() {
        #expect(CourseRole.student < CourseRole.ta)
        #expect(CourseRole.ta < CourseRole.instructor)
        #expect(CourseRole.student < CourseRole.instructor)
    }

    /// The other direction, so a flip cannot pass by satisfying only the first
    /// set. `<` and `>` disagreeing is the entire content of the mutation.
    @Test func theRelationIsNotReversible() {
        #expect(!(CourseRole.ta < CourseRole.student))
        #expect(!(CourseRole.instructor < CourseRole.ta))
        #expect(!(CourseRole.instructor < CourseRole.student))
    }

    /// A role is never strictly less than itself, and `>=` — the form every
    /// gate is actually written in — admits it.
    @Test func aRoleMeetsItsOwnBar() {
        for role in CourseRole.allCases {
            #expect(!(role < role))
            #expect(role >= role, "\(role) must clear its own atLeast check")
        }
    }

    /// The gate semantics the ranks exist for, spelled out: `atLeast: .ta`
    /// admits TAs and instructors and nobody else; `atLeast: .instructor`
    /// admits instructors only. Written as the comparison the gates perform, so
    /// this fails if the relation is inverted rather than if a gate is
    /// refactored.
    @Test func atLeastAdmitsExactlyTheRolesItNames() {
        #expect(CourseRole.allCases.filter { $0 >= .student } == CourseRole.allCases)
        #expect(CourseRole.allCases.filter { $0 >= .ta } == [.ta, .instructor])
        #expect(CourseRole.allCases.filter { $0 >= .instructor } == [.instructor])
    }

    /// `allCases` order is the privilege order, which is what lets the
    /// assertions above be written as literals — and what a roster UI relies on
    /// when it lists roles.
    @Test func declarationOrderMatchesPrivilegeOrder() {
        #expect(CourseRole.allCases == CourseRole.allCases.sorted())
    }
}
