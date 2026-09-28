// Tests/CoreTests/LTIRoleMappingTests.swift
//
// `LTIRoleMapping` decides what course authority an LMS launch grants
// (docs/lti-1-3.md "Role mapping"). The two rules most worth pinning are the
// ones a plain "highest role wins" would break: a TA arrives carrying the
// Instructor principal role too, and an institution-level Instructor is not an
// instructor in a course they take as a learner.

import Testing

@testable import Core

@Suite struct LTIRoleMappingTests {
    static let membership = "http://purl.imsglobal.org/vocab/lis/v2/membership"
    static let institution = "http://purl.imsglobal.org/vocab/lis/v2/institution/person"
    static let system = "http://purl.imsglobal.org/vocab/lis/v2/system/person"

    @Test(arguments: [
        ("\(membership)#Instructor", CourseRole.instructor),
        ("\(membership)#Administrator", CourseRole.instructor),
        ("\(membership)#ContentDeveloper", CourseRole.instructor),
        ("\(membership)#Learner", CourseRole.student),
        ("\(membership)/Learner#Learner", CourseRole.student),
        ("\(membership)/Instructor#TeachingAssistant", CourseRole.ta),
        ("\(membership)/Instructor#Grader", CourseRole.ta),
        ("Instructor", CourseRole.instructor),
        ("Learner", CourseRole.student),
    ])
    func singleContextRoleMaps(role: String, expected: CourseRole) {
        #expect(LTIRoleMapping.courseRole(forRoles: [role]) == expected)
    }

    @Test func teachingAssistantWinsOverTheInstructorPrincipalSentBesideIt() {
        let roles = ["\(Self.membership)#Instructor", "\(Self.membership)/Instructor#TeachingAssistant"]
        #expect(LTIRoleMapping.courseRole(forRoles: roles) == .ta)
    }

    @Test func highestContextRoleWinsWithoutATeachingAssistantSubRole() {
        let roles = ["\(Self.membership)#Learner", "\(Self.membership)#Instructor"]
        #expect(LTIRoleMapping.courseRole(forRoles: roles) == .instructor)
    }

    @Test func institutionAndSystemRolesGrantNoCourseRole() {
        let roles = ["\(Self.institution)#Instructor", "\(Self.system)#Administrator"]
        #expect(LTIRoleMapping.courseRole(forRoles: roles) == nil)
    }

    @Test func institutionInstructorTakingACourseAsLearnerIsAStudent() {
        let roles = ["\(Self.institution)#Instructor", "\(Self.membership)#Learner"]
        #expect(LTIRoleMapping.courseRole(forRoles: roles) == .student)
    }

    @Test(arguments: [
        [String](),
        ["\(membership)#Mentor"],
        ["\(membership)#"],
        ["\(membership)/Instructor"],
        ["urn:lti:role:ims/lis/Instructor"],
        ["   "],
    ])
    func unmappableRolesGrantNothing(roles: [String]) {
        #expect(LTIRoleMapping.courseRole(forRoles: roles) == nil)
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(LTIRoleMapping.courseRole(forRoles: [" \(Self.membership)#Learner\n"]) == .student)
    }
}
